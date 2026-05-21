# frozen_string_literal: true

require 'spec_helper'

class NeedRunner
  include Errands::Runner
  include Errands::LousyCompat

  thread_accessor :bim, :bam, :pile, :different_running_thread, :previous_worker

  def initialize(options)
    @future_running_mode = options[:running_mode]
    @limit = options[:limit]
    @exit_on_limit = options[:exit_on_limit]
    @faulty_other_job = options[:faulty_other_job]
  end

  def startup
    { bim: :bim_value,
      bam: :bam_value,
      pile: [],
      limit: @limit,
      exit_on_limit: @exit_on_limit,
      config: { frequencies: { worker: 1 } },
      faulty_other_job: @faulty_other_job }
  end

  def start(*_)
    super
    our[:other_job_pile] = receptors[:other_job_pile]
    our[:dir] = receptors[:dir]
    wait_for :worker
    @running_mode = @future_running_mode if @future_running_mode
  end

  def job
    our[:dir].concat Dir['*']
    our[:dir].shift
  end

  def process(job)
    pile.push job
    job
  end

  def other_job
    running do
      i = 0
      rescued_loop do
        i += 1

        s = our[:faulty_other_job] && i == 2 ? i : i.to_s
        my[:receptor_track] = { receptor: our[:other_job_pile] }
        our[:dir] << s
        sleep 0.3
      end
    end
  end

  def other_dumb_job(err = :dumb)
    errands err
  end

  def dumb
    1 / 0
  end

  def crash
    load 'doumac'
  end

  def different_running
    running do
      our[:different_running_thread] = Thread.current
    end
  end

  def worker_done?
    our[:limit] && pile.size >= our[:limit]
  end

  def worker_done_marker
    our[:worker_done]
  end

  def stop_worker
    worker_done
  end

  def worker_done
    if our[:exit_on_limit]
      (our[:events] ||= []) << [:stop]
      sleep
    else
      pile.clear
      our[:limit] = 1000
    end
  end

  def log_error(err, data, ctx)
    normalized = err.message.sub(/:\s*\d+\z/, '')
    super || receptors[:errors] << normalized
  end
end

class OtherRunner < NeedRunner
  started_workers :other_job
end

class EssentialRunner < NeedRunner
  started_workers :other_job

  def stopped_threads
    super - [:other_job]
  end
end

class OtherExclusiveRunner < OtherRunner
  default_workers [:other_job]

  startups << :additional_startup

  def additional_startup
    { config: { frequencies: { worker: 2, other_job: 2 } }, additional_startup: true }
  end

  def exit
    our[:exit] = true
  end
end

describe NeedRunner do # rubocop:disable Metrics/BlockLength
  let(:needy) { described_class.new needy_params }
  let(:running_mode) { nil }
  let(:limit) { nil }
  let(:exit_on_limit) { nil }
  let(:start_needy) { true }
  let(:needy_params) do
    { running_mode: running_mode,
      limit: limit,
      exit_on_limit: exit_on_limit }
  end

  before do
    Errands::TestHelpers::Wrapper.help needy if start_needy
  end

  describe 'new' do
    let(:start_needy) { false }

    it 'should not be started with only new' do
      expect(needy.started?).to be_falsy
    end
  end

  describe 'thread_accessor' do
    before do
      needy.bam = :that_bam
      needy.bim = :that_bim
    end

    it 'should have defined accessors' do
      expect(needy.bam).to eq :that_bam
      expect(needy.bim).to eq :that_bim
    end
  end

  describe 'start' do
    before do
      needy.wait_for :worker_iteration
    end

    context 'instance method' do
      it 'should have launched basic function threads' do
        expect(needy.status.values.size).to eq 3
        expect(needy.status[:starter]).not_to be_falsy
        expect(needy.status[:worker]).not_to be_falsy
        expect(needy.status[:process]).not_to be_falsy
      end

      it 'should have set accessors values' do
        expect(needy.bim).to eq :bim_value
        expect(needy.bam).to eq :bam_value
        expect(needy.pile).to be_a_kind_of Array
      end
    end

    context 'class method start' do
      let(:needy) { NeedRunner.start needy_params }

      it 'should have launched basic function threads' do
        expect(needy.status.values.size).to eq 3
        expect(needy.status[:starter]).not_to be_falsy
        expect(needy.status[:worker]).not_to be_falsy
        expect(needy.status[:process]).not_to be_falsy
      end

      it 'should have set accessors values' do
        expect(needy.bim).to eq :bim_value
        expect(needy.bam).to eq :bam_value
        expect(needy.pile).to be_a_kind_of Array
      end
    end

    context 'OtherExclusiveRunner' do
      let(:needy) { OtherExclusiveRunner.new needy_params }

      describe 'startup' do
        it 'should have gotten additional configuration' do
          expect(needy.send(:our)[:config]).to eq({ frequencies: { worker: 1, other_job: 2 } })
          expect(needy.send(:our)[:additional_startup]).to be_truthy
        end
      end

      describe 'default_workers' do
        it "should not include the worker 'worker' in the started workers" do
          expect(needy.class.started_workers).to eq [:other_job]
        end

        context 'subsequent starter worker' do
          before do
            needy.starter :worker
          end

          it "should now include the worker 'worker' in the started workers" do
            expect(needy.class.started_workers).to eq %i[other_job worker]
          end
        end
      end
    end
  end

  describe 'starter routine' do
    before do
      needy.previous_worker = needy.threads[:worker]
      needy.stop :worker
      needy.wait_for :worker, :alive?
    end

    it 'should restart a defunct worker' do
      expect(needy.threads[:worker]).not_to eq needy.previous_worker
    end
  end

  describe 'breaking_loop and work_done' do
    let(:limit) { 40 }

    context 'exit' do
      let(:exit_on_limit) { true }

      before do
        needy.wait_for :worker_done
      end

      it 'should have stopped after reaching the limit' do
        expect(needy.status.values.uniq).to eq ['sleep']
        expect(needy.pile.size).to be >= limit
        expect(needy.events).to eq [[:stop]]
        expect(needy.threads[:worker].status).to eq 'sleep'
      end
    end

    context 'no done worker' do
      before do
        needy.previous_worker = needy.threads[:worker]
        needy.wait_for :worker, :alive?, false
        needy.wait_for :worker, :alive?
      end

      it 'should have stopped after reaching the limit' do
        expect(needy.threads[:worker]).not_to eq needy.previous_worker
        expect(needy.worker_done_marker).to be_falsy
      end
    end

    describe 'receptor_track' do
      let(:faulty) { {} }
      let(:needy) { OtherRunner.new needy_params.merge(faulty) }

      context 'correct' do
        before do
          needy.wait_for :other_job_pile, :size, 3
        end

        it 'should have stashed products of other_job in a specific pile' do
          results = needy.receptors[:other_job_pile].map { |e| e[:result] }
          expect(results).to include(*%w[2 3])
        end
      end

      context 'faulty' do
        context 'loop' do
          let(:faulty) { { faulty_other_job: true } }

          before do
            needy.wait_for :other_job_pile, :size, 3
          end

          it 'should log an error on tracking' do
            expect(needy.receptors[:errors]).to include("can't modify frozen Integer")
          end
        end

        context 'dumb' do
          before do
            needy.other_dumb_job
            sleep 0.5
          end

          it 'should log an error on tracking' do
            expect(needy.receptors[:errors]).to include('divided by 0')
          end
        end

        context 'dumb' do
          before do
            needy.other_dumb_job :crash
            sleep 0.5
          end

          it 'should log an error on tracking' do
            expect(needy.receptors[:errors]).to include('cannot load such file -- doumac')
          end
        end
      end
    end

    describe 'stop' do
      context 'OtherRunner' do
        let(:needy) { OtherRunner.new needy_params }

        before do
          needy.wait_for :worker, :alive?
          needy.wait_for :other_job, :alive?
          needy.stop :starter, :worker
        end

        it 'should respond to started? accordintgly' do
          expect(needy.started?).to be_truthy
        end

        it 'should have set another worker to be started' do
          expect(needy.class.started_workers).to eq %i[worker other_job]
        end

        it 'should have set another worker to be stopped when stop is required' do
          expect(needy.stopped_threads.sort).to eq %i[other_job process starter worker]
        end

        it 'should have stopped basic threads' do
          expect(needy.threads.values_at(:starter, :worker).any?(&:alive?)).to be_falsy
          expect(needy.stopped?).to be_falsy
        end

        context 'all stopped' do
          before do
            needy.stop
          end

          it 'should have set the stopped flag' do
            expect(needy.threads[:other_job]).to be_nil
            expect(needy.stopped?).to be_truthy
          end
        end
      end

      context 'EssentialRunner' do
        let(:needy) { EssentialRunner.new needy_params }

        before do
          needy.wait_for :worker, :alive?
          needy.wait_for :other_job, :alive?
          needy.stop :starter, :worker
        end

        it 'should respond to started? accordintgly' do
          expect(needy.started?).to be_truthy
        end

        it 'should have set another worker to be started' do
          expect(needy.class.started_workers).to eq %i[worker other_job]
        end

        it 'should have set another worker to be stopped when stop is required' do
          expect(needy.stopped_threads.sort).to eq %i[process starter worker]
        end

        it 'should have stopped basic threads' do
          expect(needy.threads.values_at(:starter, :worker).any?(&:alive?)).to be_falsy
          expect(needy.stopped?).to be_falsy
        end

        context 'all stopped' do
          before do
            needy.stop
          end

          it 'should have set the stopped flag' do
            expect(needy.stopped?).to be_truthy
            expect(needy.threads[:other_job]).to be_truthy
          end
        end
      end
    end

    describe 'running_mode' do
      let(:running_mode) { :instance_exec }

      before do
        needy.different_running
      end

      it 'should not have used threads' do
        expect(needy.different_running_thread).to eq Thread.main
      end
    end
  end

  describe 'start && run' do
    let(:start_needy) { false }

    before do
      Errands::TestHelpers::Wrapper.helper.helped needy
    end

    context 'start' do
      before do
        needy.start
        sleep 0.3 until needy.started?
        needy.wait_for :worker
        needy.wait_for :worker_iteration
      end

      it 'should be properly run' do
        expect([needy.threads, needy.receptors].all?).to be_truthy
        expect(needy.events).to be_falsy
        expect(needy.started?).to be_truthy
      end
    end

    context 'run' do
      let(:needy) { NeedRunner.threaded_run needy_params }

      before do
        sleep 0.3 until needy.started?
        needy.wait_for :worker
        needy.wait_for :worker_iteration
      end

      it 'should be properly run' do
        expect([needy.threads, needy.events, needy.receptors].all?).to be_truthy
        expect(needy.started?).to be_truthy
      end

      context 'events' do
        before do
          Errands::TestHelpers::Wrapper.helper.push_event [:stop]
          needy.wait_for :stopped
        end

        it 'should have received stop signal' do
          expect(needy.stopped?).to be_truthy
        end
      end
    end
  end

  describe 'exit_on_stop' do
    let(:needy) { OtherExclusiveRunner.new needy_params }

    before do
      needy.exit_on_stop
    end

    it 'it should have called stop and exit' do
      expect(needy.stopped?).to be_truthy
      expect(needy.send(:our)[:exit]).to be_truthy
    end
  end

  after do
    Errands::TestHelpers::Wrapper.after
  end
end
