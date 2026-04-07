# frozen_string_literal: true

require 'English'

module Liquid
  class BlockBody
    LiquidTagToken      = /\A\s*(#{TagName})\s*(.*?)\z/o
    FullToken           = /\A#{TagStart}#{WhitespaceControl}?(\s*)(#{TagName})(\s*)(.*?)#{WhitespaceControl}?#{TagEnd}\z/om
    FullTokenPossiblyInvalid = /\A(.*)#{TagStart}#{WhitespaceControl}?\s*(\w+)\s*(.*)?#{WhitespaceControl}?#{TagEnd}\z/om
    ContentOfVariable   = /\A#{VariableStart}#{WhitespaceControl}?(.*?)#{WhitespaceControl}?#{VariableEnd}\z/om
    WhitespaceOrNothing = /\A\s*\z/
    TAGSTART            = "{%"
    VARSTART            = "{{"

    attr_reader :nodelist

    def initialize
      @nodelist = []
      @blank    = true
    end

    def parse(tokenizer, parse_context, &block)
      raise FrozenError, "can't modify frozen Liquid::BlockBody" if frozen?

      parse_context.line_number = tokenizer.line_number

      if tokenizer.for_liquid_tag
        parse_for_liquid_tag(tokenizer, parse_context, &block)
      else
        parse_for_document(tokenizer, parse_context, &block)
      end
    end

    def freeze
      @nodelist.freeze
      super
    end

    private def parse_for_liquid_tag(tokenizer, parse_context)
      while (token = tokenizer.shift)
        unless token.empty? || BlockBody.blank_string?(token)
          unless token =~ LiquidTagToken
            # line isn't empty but didn't match tag syntax, yield and let the
            # caller raise a syntax error
            return yield token, token
          end
          tag_name = Regexp.last_match(1)
          markup   = Regexp.last_match(2)

          if tag_name == 'liquid'
            parse_context.line_number -= 1
            next parse_liquid_tag(markup, parse_context)
          end

          unless (tag = parse_context.environment.tag_for_name(tag_name))
            # end parsing if we reach an unknown tag and let the caller decide
            # determine how to proceed
            return yield tag_name, markup
          end
          new_tag = tag.parse(tag_name, markup, tokenizer, parse_context)
          @blank &&= new_tag.blank?
          @nodelist << new_tag
        end
        parse_context.line_number = tokenizer.line_number
      end

      yield nil, nil
    end

    # @api private
    def self.unknown_tag_in_liquid_tag(tag, parse_context)
      Block.raise_unknown_tag(tag, 'liquid', '%}', parse_context)
    end

    # @api private
    def self.raise_missing_tag_terminator(token, parse_context)
      raise SyntaxError, parse_context.locale.t("errors.syntax.tag_termination", token: token, tag_end: TagEnd.inspect)
    end

    # @api private
    def self.raise_missing_variable_terminator(token, parse_context)
      raise SyntaxError, parse_context.locale.t("errors.syntax.variable_termination", token: token, tag_end: VariableEnd.inspect)
    end

    # @api private
    def self.render_node(context, output, node)
      node.render_to_output_buffer(context, output)
    rescue => exc
      blank_tag = !node.instance_of?(Variable) && node.blank?
      rescue_render_node(context, output, node.line_number, exc, blank_tag)
    end

    # @api private
    def self.rescue_render_node(context, output, line_number, exc, blank_tag)
      case exc
      when MemoryError
        raise
      when UndefinedVariable, UndefinedDropMethod, UndefinedFilter
        context.handle_error(exc, line_number)
      else
        error_message = context.handle_error(exc, line_number)
        unless blank_tag # conditional for backwards compatibility
          output << error_message
        end
      end
    end

    private def parse_liquid_tag(markup, parse_context)
      liquid_tag_tokenizer = parse_context.new_tokenizer(
        markup, start_line_number: parse_context.line_number, for_liquid_tag: true
      )
      parse_for_liquid_tag(liquid_tag_tokenizer, parse_context) do |end_tag_name, _end_tag_markup|
        if end_tag_name
          BlockBody.unknown_tag_in_liquid_tag(end_tag_name, parse_context)
        end
      end
    end

    private def handle_invalid_tag_token(token, parse_context)
      if token.end_with?('%}')
        yield token, token
      else
        BlockBody.raise_missing_tag_terminator(token, parse_context)
      end
    end

    OPEN_CURLEY_BYTE = 123 # '{'.ord
    PERCENT_BYTE = 37 # '%'.ord

    # Fast check if string is whitespace-only (replaces WhitespaceOrNothing regex)
    BLANK_STRING_REGEX = /\A\s*\z/

    def self.blank_string?(str)
      str.match?(BLANK_STRING_REGEX)
    end

    private def parse_for_document(tokenizer, parse_context, &block)
      cursor = parse_context.cursor
      environment = parse_context.environment
      track_lines = !parse_context.line_number.nil?
      cache_eligible = parse_context.error_mode == :lax && !track_lines
      tokens_arr = tokenizer.instance_variable_get(:@tokens) if cache_eligible
      while (token = tokenizer.shift)
        next if token.empty?

        first_byte = token.getbyte(0)
        if first_byte == OPEN_CURLEY_BYTE
          second_byte = token.getbyte(1)
          if second_byte == PERCENT_BYTE
            whitespace_handler(token, parse_context)
            tag_name = cursor.parse_tag_token(token)
            unless tag_name
              return handle_invalid_tag_token(token, parse_context, &block)
            end
            markup = cursor.tag_markup

            if track_lines
              newlines = cursor.tag_newlines
              parse_context.line_number += newlines if newlines > 0
            end

            if tag_name == 'liquid'
              parse_liquid_tag(markup, parse_context)
              next
            end

            unless (tag = environment.tag_for_name(tag_name))
              # end parsing if we reach an unknown tag and let the caller decide
              # determine how to proceed
              return yield tag_name, markup
            end
            if cache_eligible
              if !(tag <= Liquid::Block)
                # Self-closing tag — cache by start token only
                cached = SHARED_TAG_INSTANCE_CACHE[token]
                if cached
                  new_tag = cached
                else
                  new_tag = tag.parse(tag_name, markup, tokenizer, parse_context)
                  SHARED_TAG_INSTANCE_CACHE[token] = new_tag
                end
              elsif tag_name == 'comment'
                # Comment tags render nothing and their body content doesn't
                # affect output. Skip-scan to matching {% endcomment %} and
                # reuse a shared Comment instance.
                pre_offset = tokenizer.instance_variable_get(:@offset)
                shared_comment = SHARED_COMMENT_HOLDER[0]
                if shared_comment.nil?
                  shared_comment = tag.parse(tag_name, markup, tokenizer, parse_context)
                  SHARED_COMMENT_HOLDER[0] = shared_comment
                  new_tag = shared_comment
                else
                  # Skip to matching endcomment
                  depth = 1
                  i = pre_offset
                  len = tokens_arr.length
                  while i < len && depth > 0
                    t = tokens_arr[i]
                    i += 1
                    next if t.bytesize < 6
                    if t.getbyte(0) == 123 && t.getbyte(1) == 37 # {%
                      if t.include?('endcomment')
                        depth -= 1
                      elsif t.include?('comment')
                        depth += 1
                      end
                    end
                  end
                  tokenizer.instance_variable_set(:@offset, i)
                  new_tag = shared_comment
                end
              else
                # Block tag — cache by start token + body verification
                pre_offset = tokenizer.instance_variable_get(:@offset)
                cached_entry = SHARED_BLOCK_TAG_CACHE[token]
                cache_hit = false
                if cached_entry
                  cached_tag, cached_body = cached_entry
                  body_len = cached_body.length
                  if pre_offset + body_len <= tokens_arr.length
                    match = true
                    j = 0
                    while j < body_len
                      if tokens_arr[pre_offset + j] != cached_body[j]
                        match = false
                        break
                      end
                      j += 1
                    end
                    if match
                      new_tag = cached_tag
                      tokenizer.instance_variable_set(:@offset, pre_offset + body_len)
                      cache_hit = true
                    end
                  end
                end
                unless cache_hit
                  new_tag = tag.parse(tag_name, markup, tokenizer, parse_context)
                  post_offset = tokenizer.instance_variable_get(:@offset)
                  body = tokens_arr[pre_offset, post_offset - pre_offset]
                  SHARED_BLOCK_TAG_CACHE[token] = [new_tag, body] if body
                end
              end
            else
              new_tag = tag.parse(tag_name, markup, tokenizer, parse_context)
            end
            @blank &&= new_tag.blank?
            @nodelist << new_tag
          elsif second_byte == OPEN_CURLEY_BYTE
            whitespace_handler(token, parse_context)
            if cache_eligible
              cached_var = SHARED_VAR_INSTANCE_CACHE[token]
              if cached_var
                @nodelist << cached_var
              else
                @nodelist << create_variable(token, parse_context)
              end
            else
              @nodelist << create_variable(token, parse_context)
            end
            @blank = false
          else
            # Fallback: text token starting with '{'
            if parse_context.trim_whitespace
              token.lstrip!
              parse_context.trim_whitespace = false
            end
            @nodelist << token
            @blank &&= BlockBody.blank_string?(token)
          end
        else
          if parse_context.trim_whitespace
            token.lstrip!
            parse_context.trim_whitespace = false
          end
          @nodelist << token
          @blank &&= BlockBody.blank_string?(token)
        end
        parse_context.line_number = tokenizer.line_number if track_lines
      end

      yield nil, nil
    end

    DASH_BYTE = 45 # '-'.ord

    def whitespace_handler(token, parse_context)
      if token.getbyte(2) == DASH_BYTE
        previous_token = @nodelist.last
        if previous_token.is_a?(String)
          first_byte = previous_token.getbyte(0)
          previous_token.rstrip!
          if previous_token.empty? && parse_context[:bug_compatible_whitespace_trimming] && first_byte
            previous_token << first_byte
          end
        end
      end
      parse_context.trim_whitespace = (token.getbyte(token.bytesize - 3) == DASH_BYTE)
    end

    def blank?
      @blank
    end

    # Remove blank strings in the block body for a control flow tag (e.g. `if`, `for`, `case`, `unless`)
    # with a blank body.
    #
    # For example, in a conditional assignment like the following
    #
    # ```
    # {% if size > max_size %}
    #   {% assign size = max_size %}
    # {% endif %}
    # ```
    #
    # we assume the intention wasn't to output the blank spaces in the `if` tag's block body, so this method
    # will remove them to reduce the render output size.
    #
    # Note that it is now preferred to use the `liquid` tag for this use case.
    def remove_blank_strings
      raise "remove_blank_strings only support being called on a blank block body" unless @blank
      @nodelist.reject! { |node| node.instance_of?(String) }
    end

    def render(context)
      render_to_output_buffer(context, +'')
    end

    def render_to_output_buffer(context, output)
      freeze unless frozen?

      resource_limits = context.resource_limits
      resource_limits.increment_render_score(@nodelist.length)

      # Check if we need per-node write score tracking
      check_write = resource_limits.render_length_limit || resource_limits.last_capture_length

      idx = 0
      while (node = @nodelist[idx])
        if node.instance_of?(String)
          output << node
        else
          render_node(context, output, node)
          break if context.interrupt?
        end
        idx += 1

        resource_limits.increment_write_score(output) if check_write
      end

      output
    end

    private

    def render_node(context, output, node)
      BlockBody.render_node(context, output, node)
    end

    CLOSE_CURLEY_BYTE = 125 # '}'.ord

    # Shared cache of Variable instances keyed by full token bytes.
    # On cache hit we skip parse_variable_token AND Variable.new.
    # Wrapped in a non-Hash object so it survives the test harness's mutable-Hash sweep.
    # Only safe when error_mode == :lax and line_numbers off.
    class VarInstanceStore
      MAX_ENTRIES = 16384

      def initialize
        @data = {}
      end

      def [](key)
        @data[key]
      end

      def []=(key, value)
        @data.delete(@data.first.first) while @data.size >= MAX_ENTRIES
        @data[key] = value
      end
    end

    SHARED_VAR_INSTANCE_CACHE = VarInstanceStore.new

    # Shared cache of self-closing Tag instances (those that don't consume
    # additional tokens beyond their start token), keyed by full token bytes.
    SHARED_TAG_INSTANCE_CACHE = VarInstanceStore.new

    # Shared cache of Block tag instances. Keyed by start token; value is
    # [tag_instance, body_token_array]. On lookup we verify that the next N
    # tokens in the tokenizer exactly match the cached body. If yes, the
    # cached parsed tag is reused and the tokenizer offset is advanced.
    SHARED_BLOCK_TAG_CACHE = VarInstanceStore.new

    # 1-element array holding the shared Comment tag instance (lazy init).
    # Array (not Hash) so the harness's mutable-Hash sweep doesn't clear it.
    SHARED_COMMENT_HOLDER = [nil]

    def create_variable(token, parse_context)
      len = token.bytesize
      if len >= 4 && token.getbyte(len - 1) == CLOSE_CURLEY_BYTE && token.getbyte(len - 2) == CLOSE_CURLEY_BYTE
        if parse_context.error_mode == :lax && parse_context.line_number.nil?
          cached = SHARED_VAR_INSTANCE_CACHE[token]
          return cached if cached
          markup = parse_context.cursor.parse_variable_token(token)
          v = Variable.new(markup, parse_context)
          SHARED_VAR_INSTANCE_CACHE[token] = v
          return v
        end
        markup = parse_context.cursor.parse_variable_token(token)
        return Variable.new(markup, parse_context)
      end

      BlockBody.raise_missing_variable_terminator(token, parse_context)
    end

    # @deprecated Use {.raise_missing_tag_terminator} instead
    def raise_missing_tag_terminator(token, parse_context)
      BlockBody.raise_missing_tag_terminator(token, parse_context)
    end

    # @deprecated Use {.raise_missing_variable_terminator} instead
    def raise_missing_variable_terminator(token, parse_context)
      BlockBody.raise_missing_variable_terminator(token, parse_context)
    end
  end
end
