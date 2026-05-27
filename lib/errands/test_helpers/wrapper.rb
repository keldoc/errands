# frozen_string_literal: true

require 'errands/alternate_private_access'

module Errands
  module TestHelpers
    module OurStore
      def initialize(*args)
        s = if args.size == 1 && args.first.is_a?(Hash)
              args.first.delete(:startup).tap { args.pop if args.first.empty? }
            elsif args.last.is_a?(Hash)
              args.pop[:startup]
            end

        our_store! (s.is_a?(Hash) ? s : send(s)) || {}

        super
      end
    end

    module ResetStartedWorkers
      def reset_started_workers
        @started_workers = nil
      end
    end

    module StopAll
      def stopped_threads
        threads.keys.reject { |k| k.to_s =~ /^errands_.+_stop$/ }
      end
    end

    class Wrapper
      class Vanilla
        extend ThreadAccessor::PrivateAccess

        class << self
          def theirs
            our
          end
        end
      end

      include Errands::AlternatePrivateAccess

      def self.helper
        @instance = new
      end

      def self.help(helped, _options = {}, &block)
        helper
        # ~ @instance.theirs_reset! unless options[:reset] == false
        @instance.help helped, &block
      end

      def initialize
        set_store :errands_test
        our_store!
      end

      def theirs
        Vanilla.theirs
      end

      def help(helped)
        (our[:helped] = helped).tap do |i|
          i.instance_variable_set '@errands_wait_timeout', 10
          i.start unless i.started?
          yield i if block_given?
        end
      end

      def helped(inf = nil)
        inf ? our[:helped] = inf : our[:helped]
      end

      def push_event(err)
        theirs && theirs[:events] && theirs[:events] << err
      end

      def theirs_reset!
        theirs&.clear
      end

      def self.after
        threads_cleanup

        if @instance
          @instance.stop_helped if @instance.helped
          @instance.theirs_reset!
        end

        @instance = nil
      end

      def self.threads_cleanup
        while (t = Thread.list.select { |t| t[:errands] } - [Thread.main]).any?
          t.each &:exit
        end
      end

      def stop_helped
        helped.stop
        helped.wait_for :stopped
      end
    end
  end
end
