# frozen_string_literal: true

require 'English'
module Errands
  module ThreadAccessor
    def self.extended(klass)
      klass.include PrivateAccess
    end

    def thread_accessor(*accessors)
      accessors.each do |a|
        define_method a, -> { our[a] }
        define_method "#{a}=", ->(v) { our[a] = v }
      end
    end

    module PrivateAccess
      def err(hash = {})
        his_store! Thread.current, hash
      end

      private

      def our_store!(hash = nil)
        Thread.main[:errands] = hash || {}
      end

      def his_store!(thread, hash = nil)
        thread[:errands] = hash || {}
      end

      def my
        Thread.current[:errands]
      end

      def his(thread)
        thread[:errands]
      end

      def our
        Thread.main[:errands]
      end
    end
  end

  module Started
    def start(*args)
      new(*args).tap(&:start)
    end

    def run(*args)
      new(*args).tap do |e|
        Process.daemon if (callee = __callee__) == :daemon
        startups << define_method(:startups_alternate_run) { { callee => true } } if __callee__ != __method__
        e.run
      end
    end

    alias daemon run
    alias threaded_run run
    alias noop_run run

    def started_workers(*args)
      (@started_workers ||= [:worker]).concat args.flatten.map(&:to_sym)
    end

    def startups
      @startups ||= [:minimal_startup]
    end

    private

    def default_workers(*args)
      started_workers(*args).tap { |s| s.delete :worker }
    end
  end

  class Receptors < Hash
    class Receptor < Array
      module Track
        def track(val, rec = nil)
          val.__send__ "instance_variable_#{rec ? :set : :get}", *['@receptor_track', rec].compact
        rescue StandardError => e
          my.merge!(data: val, error: :tracking_error)
          raise e
        end
      end

      include ThreadAccessor::PrivateAccess
      include Track

      attr_reader :name

      def initialize(name) # rubocop:disable Lint/MissingSuper
        @name = name
      end

      def shift(*args)
        my[:data] = super.tap { |value| my.merge! receptor_track: track(value), latency: empty? }
      end

      def <<(value)
        return if value.nil?

        track value, my[:receptor_track] if my
        super.tap { our[:threads][@name]&.run }
      end
    end

    def default(key)
      self[key] = Receptor.new key
    end
  end

  class Runners < Hash
    include ThreadAccessor::PrivateAccess

    def [](key)
      val = super
      val if val&.alive?
    end

    def []=(key, val)
      our[key] = super if val.is_a? Thread
    end

    def delete(key)
      our.delete key
      super
    end

    def stopping_order(all = false)
      scope(:type, :starter).merge(scope(:type, :data_acquisition)).merge all ? self : {}
    end

    def key_sliced(*list)
      select_keys = keys & list.flatten
      typecast(select { |k, _v| select_keys.include? k })
    end

    def alive
      typecast(select { |k, _v| self[k] })
    end

    def scope(scp, value = true)
      typecast(select { |_k, v| his(v)[scp] == value })
    end

    private

    def typecast(hash)
      self.class.new.merge! hash
    end
  end

  module LousyCompat
    def worker
      working :worker, :process, :job
    end
  end

  module Runner # rubocop:disable Metrics/ModuleLength
    def self.included(klass)
      klass.extend(ThreadAccessor).extend(Started)
      klass.thread_accessor :events, :receptors, :threads
    end

    attr_accessor :running_mode

    def start(options = {})
      our_store! startups.merge(options)
      starter
    end

    def run(options = startups)
      start options unless started?
      our.merge! events: receptors[:events]
      our[:threaded_run] || our[:noop_run] ? running { main_loop } : main_loop
    end

    def starter(*args)
      if our[:starter]
        self.class.started_workers(*args)
      elsif !our[:noop_run]
        starting self.class.started_workers

        on_workers_started if respond_to? :on_workers_started, true
      end
    end

    def starting(started)
      log_activity ["Starting #{self.class} in #{$PROGRAM_NAME} (#{$PROCESS_ID}), at #{Time.now}, with :", our[:config],
                    "workers : #{started}", "\n"].join("\n")

      running thread_name, loop: true, started: started, type: :starter do
        Array(my[:started]).uniq.each { |s| threads[s] ||= send(*(respond_to?(s, true) ? [s] : [:working, s])) }
        sleep frequency || 1
      end
    end

    def working(*args)
      work_done, processing, data_acquisition = working_jargon(*args)
      our[work_done] = false

      running args.first, loop: true, type: :data_acquisition do
        unless my[:stop] ||= (our[work_done] = checked_send("#{work_done}?"))
          r = ready_receptor! processing
          ((r << send(data_acquisition)) && !my[:latency]) || sleep(frequency.to_i)
        end
      end
    end

    def exit_on_stop
      stop
      exit
    end

    def stop(*args)
      [false, true].each do |all|
        list = threads.key_sliced(args.any? ? args : stopped_threads)
        list.alive.each_value { |t| his(t)[:stop] = true }
        list.stopping_order(all).alive.each { |n, t| exiting(n, !all || t.stop?) }
      end

      stopped?
      threads.key_sliced(args.any? ? args : stopped_threads).alive.empty?
    end

    def status
      {}.tap { |s| threads.each { |name, t| s[name] = t.status } }
    end

    def wait_for(key, meth = nil, result = true)
      time = Time.now.to_f
      loop do
        break if @errands_wait_timeout && Time.now.to_f - time > @errands_wait_timeout

        done = if meth && our[key].respond_to?(meth, true)
                 begin
                   (our[key].send(meth) == result)
                 rescue StandardError
                   nil
                 end
               else
                 (!!our[key] == result) # rubocop:disable Style/DoubleNegation
               end
        break if done

        Thread.pass
      end
    end

    def stopped?
      our[:stopped] = threads.key_sliced(stopped_threads).alive.empty?.tap do |bool|
        if bool
          log_activity Time.now, "#{self.class} #{begin
            name
          rescue StandardError
            nil
          end} : All activities stopped"
        end
      end
    end

    def started?
      !!our && !!threads && our[:started] = !stopped?
    end

    private

    def minimal_startup
      { threads: Runners.new, receptors: Receptors.new }
    end

    def frequency(name = nil)
      our[:config] && our[:config][:frequencies] && our[:config][:frequencies][name || my[:name]]
    end

    def main_loop
      rescued_loop do
        break if stopped?

        (e = events.shift) ? errands(*e) : sleep(frequency(:main_loop) || 1)
      end

      log_activity Time.now, "#{self.class} #{begin
        name
      rescue StandardError
        nil
      end} : Exiting main loop"
    end

    def ready_receptor!(processing)
      receptors[processing].tap { threads[processing] ||= spring processing }
    end

    def spring(processing)
      running processing, loop: true, deletable: true do
        data = receptors[my[:name]].shift || Thread.stop || receptors[my[:name]].shift
        data && send(processing, data).tap do |r|
          if my[:receptor_track] && my[:receptor_track][:receptor].name != my[:name]
            my[:receptor_track][:receptor] << my[:receptor_track].merge(result: r).reject { |k, _v| k == :receptor }
          end
        end
      end
    end

    def errands(errand, *args)
      running("#{thread_name(1)}_#{errand}".to_sym, deletable: true) { send errand, *args }
    end

    def running(name = thread_name, options = {}, &block)
      if @running_mode
        send @running_mode, &block
      else
        thread = Thread.new do
          (my && my[:name] && (my[:named] = true)) || Thread.stop || (my[:named] = true)
          r = my[:result] = rescued_execution(&block)
          ["stop_#{name}", our[name] && "stop_#{his(our[name])[:type]}"].compact.each { |s| checked_send s }
          my[:deletable] && threads.delete(name)
          r
        end
        his_store! thread, {
          name: name,
          time: Time.now.to_f,
          stop: false,
          type: :any,
          receptor_track: my && my.delete(:receptor_track)
        }.merge(options)
        thread.run unless his(thread)[:named]
        threads[name] = thread
      end
    end

    def exiting(name, force = true)
      if force && Thread.current == our[name]
        errands(:exiting, name)
      else
        our[name] && (force || our[name].stop?) && our[name].exit
      end
      wait_for name, :alive?, false
    end

    public

    def stopped_threads
      our[:stopped_threads] || threads.keys.reject { |k| k.to_s =~ /^errands_.+_stop$/ }
    end

    private

    def thread_name(caller_depth = 2)
      caller_locations(caller_depth, 1).first.base_label.dup.tap do |n|
        n << '_' << Time.now.to_f.to_s.sub('.', '_') if n.end_with? 's'
      end.to_sym
    end

    def rescued_execution
      loop do
        our["#{my[:name]}_iteration".to_sym] = begin
          my[:stop] ? break : yield

          Time.now
        rescue StandardError, LoadError => e
          log_error e, my[:data], my
        rescue Exception => e # rubocop:disable Lint/RescueException
          log_error e, my[:data], my
          raise e
        end

        my[:loop] || break
      end
    end

    def rescued_loop(&block)
      my[:loop] = true
      rescued_execution(&block)
    end

    def checked_send(meth, recipient = self, *args)
      recipient.respond_to?(meth, true) && recipient.send(meth, *args)
    rescue StandardError
      nil
    end

    def working_jargon(started, processing = nil, data_acquisition = nil)
      [
        "#{started}_done".to_sym,
        processing || "#{started}_process".to_sym,
        data_acquisition || "#{started}_data_acquisition".to_sym
      ]
    end

    def log_error(err, data, *args)
      my[:logged] = Time.now.to_f
      log_activity ["Data : #{data}", "Error : #{err}, #{err.message}\n#{err.backtrace}",
                    "Context : #{args}"].join("\n")
    rescue StandardError => e
      puts "Got #{e} in the process of logging error #{err} "
    end

    def log_activity(*args)
      return unless our[:verbose]

      puts(args.map(&:to_s).join(' '))
    end

    def startups
      @startups ||= self.class.startups
                        .dup
                        .tap { |s| s << :startup if respond_to?(:startup, true) }
                        .uniq
                        .inject({}) do |s, m|
        extended_merge(
          s, __send__(m)
        )
      end
    end

    def extended_merge(from, to)
      from.tap do |f|
        to.each_key do |k|
          f[k] = f[k].is_a?(Hash) && to[k].is_a?(Hash) ? extended_merge(f[k], to[k]) : to[k]
        end
      end
    end
  end
end
