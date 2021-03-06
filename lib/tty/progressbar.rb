# encoding: utf-8
# frozen_string_literal: true

require 'io/console'
require 'forwardable'
require 'monitor'
require 'tty-cursor'
require 'tty-screen'

require_relative 'progressbar/configuration'
require_relative 'progressbar/formatter'
require_relative 'progressbar/meter'
require_relative 'progressbar/version'

module TTY
  # Used for creating terminal progress bar
  #
  # @api public
  class ProgressBar
    extend Forwardable
    include MonitorMixin

    ECMA_ESC = "\e".freeze
    ECMA_CSI = "\e[".freeze
    ECMA_CLR = 'K'.freeze

    DEC_RST  = 'l'.freeze
    DEC_SET  = 'h'.freeze
    DEC_TCEM = '?25'.freeze

    CURSOR_LOCK = Monitor.new

    attr_reader :format

    attr_reader :current

    attr_reader :start_at

    attr_reader :row

    def_delegators :@configuration, :total, :width, :no_width,
                   :complete, :incomplete, :head, :hide_cursor, :clear,
                   :output, :frequency, :interval, :width=

    def_delegators :@meter, :rate, :mean_rate

    def_delegator :@formatter, :use

    # Create progress bar
    #
    # @param [String] format
    #   the tokenized string that displays the output
    #
    # @param [Hash] options
    # @option options [Numeric] :total
    #   the total number of steps to completion
    # @option options [Numeric] :width
    #   the maximum width for the bars display including
    #   all formatting options
    # @option options [Boolean] :no_width
    #   true when progression is unknown defaulting to false
    # @option options [Boolean] :clear
    #   whether or not to clear the progress line
    # @option options [Boolean] :hide_cursor
    #   display or hide cursor
    # @option options [Object] :output
    #   the object that responds to print call defaulting to stderr
    # @option options [Number] :frequency
    #   the frequency with which to display bars
    # @option options [Number] :interval
    #   the period for sampling of speed measurement
    #
    # @api public
    def initialize(format, options = {})
      super()
      @format = format
      if format.is_a?(Hash)
        raise ArgumentError, "Expected bar formatting string, " \
                             "got `#{format}` instead."
      end
      @configuration = TTY::ProgressBar::Configuration.new(options)
      yield @configuration if block_given?

      @formatter = TTY::ProgressBar::Formatter.new
      @meter     = TTY::ProgressBar::Meter.new(interval)
      @callbacks = Hash.new { |h, k| h[k] = [] }

      @formatter.load
      reset
    end

    # Reset progress to default configuration
    #
    # @api public
    def reset
      @width             = 0 if no_width
      @render_period     = frequency == 0 ? 0 : 1.0 / frequency
      @current           = 0
      @last_render_time  = Time.now
      @last_render_width = 0
      @done              = false
      @stopped           = false
      @start_at          = Time.now
      @started           = false
      @tokens            = {}
      @multibar          = nil
      @row               = nil
      @first_render      = true

      @meter.clear
    end

    # Attach this bar to multi bar
    #
    # @param [TTY::ProgressBar::Multi] multibar
    #   the multibar under which this bar is registered
    #
    # @api private
    def attach_to(multibar)
      @multibar = multibar
    end

    # Start progression by drawing bar and setting time
    #
    # @api public
    def start
      synchronize do
        @started  = true
        @start_at = Time.now
        @meter.start
      end

      advance(0)
    end

    # Advance the progress bar
    #
    # @param [Object|Number] progress
    #
    # @api public
    def advance(progress = 1, tokens = {})
      return if done?

      synchronize do
        if progress.respond_to?(:to_hash)
          tokens, progress = progress, 1
        end
        @start_at  = Time.now if @current.zero? && !@started
        @current  += progress
        @tokens    = tokens
        @meter.sample(Time.now, progress)

        if !no_width && @current >= total
          finish && return
        end

        now = Time.now
        return if (now - @last_render_time) < @render_period
        render
        emit(:progress)
      end
    end

    # Iterate over collection either yielding computation to block
    # or provided Enumerator.
    #
    # @example
    #   bar.iterate(30.times) { ... }
    #
    # @param [Enumerable] collection
    #   the collection to iterate over
    #
    # @param [Integer] progress
    #   the amount to move progress bar by
    #
    # @return [Enumerator]
    #
    # @api public
    def iterate(collection, progress = 1, &block)
      update(total: collection.count)
      prog = Enumerator.new do |iter|
        collection.each do |elem|
          advance(progress)
          iter.yield(elem)
        end
      end
      block_given? ? prog.each(&block) : prog
    end

    # Update configuration options for this bar
    #
    # @param [Hash[Symbol]] options
    #   the configuration options to update
    #
    # @api public
    def update(options = {})
      synchronize do
        options.each do |name, val|
          @configuration.public_send("#{name}=", val)
        end
      end
    end

    # Advance the progress bar to the updated value
    #
    # @param [Number] value
    #   the desired value to updated to
    #
    # @api public
    def current=(value)
      value = [0, [value, total].min].max
      advance(value - @current)
    end

    # Advance the progress bar to an exact ratio.
    # The target value is set to the closest available value.
    #
    # @param [Float] value
    #   the ratio between 0 and 1 inclusive
    #
    # @api public
    def ratio=(value)
      target = (value * total).floor
      advance(target - @current)
    end

    # Ratio of completed over total steps
    #
    # @return [Float]
    #
    # @api public
    def ratio
      synchronize do
        proportion = total > 0 ? (@current.to_f / total) : 0
        [[proportion, 0].max, 1].min
      end
    end

    # Render progress to the output
    #
    # @api private
    def render
      return if done?
      if hide_cursor && @last_render_width == 0 && !(@current >= total)
        write(ECMA_CSI + DEC_TCEM + DEC_RST)
      end

      formatted = @formatter.decorate(self, @format)
      @tokens.each do |token, val|
        formatted = formatted.gsub(":#{token}", val)
      end
      write(formatted, true)

      @last_render_time  = Time.now
      @last_render_width = formatted.length
    end

    # Move cursor to a row of the current bar if the bar is rendered
    # under a multibar. Otherwise, do not move and yield on current row.
    #
    # @api private
    def move_to_row
      if @multibar
        CURSOR_LOCK.synchronize do
          if @first_render
            @row = @multibar.next_row
            yield if block_given?
            output.print "\n"
            @first_render = false
          else
            lines_up = (@multibar.rows + 1) - @row
            output.print TTY::Cursor.save
            output.print TTY::Cursor.up(lines_up)
            yield if block_given?
            output.print TTY::Cursor.restore
          end
        end
      else
        yield if block_given?
      end
    end

    # Write out to the output
    #
    # @param [String] data
    #
    # @api private
    def write(data, clear_first = false)
      move_to_row do
        output.print(TTY::Cursor.column(1)) if clear_first
        characters_in = @multibar.line_inset(self) if @multibar
        output.print("#{characters_in}#{data}")
        output.flush
      end
    end

    # Resize progress bar with new configuration
    #
    # @param [Integer] new_width
    #   the new width for the bar display
    #
    # @api public
    def resize(new_width = nil)
      return if done?
      synchronize do
        clear_line
        if new_width
          self.width = new_width
        end
      end
    end

    # End the progress
    #
    # @api public
    def finish
      # reenable cursor if it is turned off
      if hide_cursor && @last_render_width != 0
        write(ECMA_CSI + DEC_TCEM + DEC_SET, false)
      end
      return if done?
      @current = total unless no_width
      render
      clear ? clear_line : write("\n", false)
    ensure
      @meter.clear
      @done = true
      emit(:done)
    end

    # Stop and cancel the progress at the current position
    #
    # @api public
    def stop
      # reenable cursor if it is turned off
      if hide_cursor && @last_render_width != 0
        write(ECMA_CSI + DEC_TCEM + DEC_SET, false)
      end
      return if done?
      render
      clear ? clear_line : write("\n", false)
    ensure
      @meter.clear
      @stopped = true
      emit(:stopped)
    end

    # Clear current line
    #
    # @api public
    def clear_line
      output.print(ECMA_CSI + '0m' + ECMA_CSI + '1000D' + ECMA_CSI + ECMA_CLR)
    end

    # Check if progress is finised
    #
    # @return [Boolean]
    #   true when progress finished, false otherwise
    #
    # @api public
    def complete?
      @done
    end

    # Check if progress is stopped
    #
    # @return [Boolean]
    #
    # @api public
    def stopped?
      @stopped
    end

    # Check if progress is finished or stopped
    #
    # @return [Boolean]
    #
    # @api public
    def done?
      @done || @stopped
    end

    # Register callback with this bar
    #
    # @param [Symbol] name
    #   the name for the event to listen for, e.i. :complete
    #
    # @return [self]
    #
    # @api public
    def on(name, &callback)
      synchronize do
        @callbacks[name] << callback
      end
      self
    end

    # Log message above the current progress bar
    #
    # @param [String] message
    #   the message to log out
    #
    # @api public
    def log(message)
      sanitized_message = message.gsub(/\r|\n/, ' ')
      if done?
        write(sanitized_message + "\n", false)
        return
      end
      sanitized_message = padout(sanitized_message)

      write(sanitized_message + "\n", true)
      render
    end

    # Determine terminal width
    #
    # @return [Integer]
    #
    # @api public
    def max_columns
      TTY::Screen.width
    end

    # Show bar format
    #
    # @return [String]
    #
    # @api public
    def to_s
      @format.to_s
    end

    # Inspect bar properties
    #
    # @return [String]
    #
    # @api public
    def inspect
      "#<#{self.class.name} " \
      "@format=\"#{format}\", " \
      "@current=\"#{@current}\", " \
      "@total=\"#{total}\", " \
      "@width=\"#{width}\", " \
      "@complete=\"#{complete}\", " \
      "@head=\"#{head}\", " \
      "@incomplete=\"#{incomplete}\", " \
      "@interval=\"#{interval}\">"
    end

    private

    # Pad message out with spaces
    #
    # @api private
    def padout(message)
      if @last_render_width > message.length
        remaining_width = @last_render_width - message.length
        message += ' ' * remaining_width
      end
      message
    end

    # Emit callback by name
    #
    # @param [Symbol]
    #   the event name
    #
    # @api private
    def emit(name, *args)
      @callbacks[name].each do |callback|
        callback.call(*args)
      end
    end
  end # ProgressBar
end # TTY
