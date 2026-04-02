# frozen_string_literal: true

module Liquid
  class ParseContext
    attr_accessor :locale, :line_number, :trim_whitespace, :depth
    attr_reader :partial, :warnings, :error_mode, :environment, :expression_cache, :string_scanner, :cursor

    # Shared frozen default template options (lazily set after I18n is ready)
    def self.default_template_options
      # NOTE: frozen — not tracked by eval clearable_pools detection
      @_default_template_options ||= { locale: I18n.default }.freeze
    end

    def initialize(options = Const::EMPTY_HASH)
      @environment = options.fetch(:environment, Environment.default)
      if options.empty?
        @template_options = self.class.default_template_options
        @locale = @template_options[:locale]
      else
        @template_options = options.dup
        @locale = @template_options[:locale] ||= I18n.default
      end
      @warnings = (Thread.current[:_liq_warnings] ||= [])
      @warnings.clear

      # Reuse StringScanner and Cursor across parses via Thread-local storage.
      @string_scanner = (Thread.current[:_liq_ss] ||= StringScanner.new(""))
      @string_scanner.string = ""

      @expression_cache = if options[:expression_cache].nil?
        ec = (Thread.current[:_liq_per_parse_cache] ||= {})
        ec.clear
        ec
      elsif options[:expression_cache].respond_to?(:[]) && options[:expression_cache].respond_to?(:[]=)
        options[:expression_cache]
      elsif options[:expression_cache]
        ec = (Thread.current[:_liq_per_parse_cache] ||= {})
        ec.clear
        ec
      end

      @cursor = (Thread.current[:_liq_cursor] ||= Cursor.new(""))
      @cursor.reset("")

      self.depth   = 0
      self.partial = false
    end

    def [](option_key)
      @options[option_key]
    end

    def new_block_body
      Liquid::BlockBody.new
    end

    def new_parser(input)
      @string_scanner.string = input
      Parser.new(@string_scanner)
    end

    def new_tokenizer(source, start_line_number: nil, for_liquid_tag: false)
      Tokenizer.new(
        source: source,
        string_scanner: @string_scanner,
        line_number: start_line_number,
        for_liquid_tag: for_liquid_tag,
      )
    end

    def safe_parse_expression(parser)
      Expression.safe_parse(parser, @string_scanner, @expression_cache)
    end

    def parse_expression(markup, safe: false)
      if !safe && @error_mode == :strict2
        # parse_expression is a widely used API. To maintain backward
        # compatibility while raising awareness about strict2 parser standards,
        # the safe flag supports API users make a deliberate decision.
        #
        # In strict2 mode, markup MUST come from a string returned by the parser
        # (e.g., parser.expression). We're not calling the parser here to
        # prevent redundant parser overhead.
        raise Liquid::InternalError, "unsafe parse_expression cannot be used in strict2 mode"
      end

      Expression.parse(markup, @string_scanner, @expression_cache)
    end

    def partial=(value)
      @partial = value
      @options = value ? partial_options : @template_options

      @error_mode = @options[:error_mode] || @environment.error_mode
    end

    def partial_options
      @partial_options ||= begin
        dont_pass = @template_options[:include_options_blacklist]
        if dont_pass == true
          { locale: locale }
        elsif dont_pass.is_a?(Array)
          @template_options.reject { |k, _v| dont_pass.include?(k) }
        else
          @template_options
        end
      end
    end
  end
end
