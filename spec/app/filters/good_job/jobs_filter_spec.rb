# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GoodJob::JobsFilter do
  subject(:filter) { described_class.new(params) }

  let(:params) { {} }

  before do
    allow(GoodJob).to receive_messages(retry_on_unhandled_error: false, preserve_job_records: true)

    ActiveJob::Base.queue_adapter = GoodJob::Adapter.new(execution_mode: :external)
    ExampleJob.set(queue: 'cron').perform_later
    GoodJob::Job.order(created_at: :asc).last.update!(cron_key: "frequent_cron")

    ActiveJob::Base.queue_adapter = GoodJob::Adapter.new(execution_mode: :inline)
    ExampleJob.set(queue: 'default').perform_later(ExampleJob::SUCCESS_TYPE)
    ExampleJob.set(queue: 'mice').perform_later(ExampleJob::ERROR_ONCE_TYPE)

    Timecop.travel 1.hour.ago
    ExampleJob.set(queue: 'elephants').perform_later(ExampleJob::DEAD_TYPE)
    5.times do
      Timecop.travel 5.minutes
      GoodJob.perform_inline
    end
    Timecop.return

    running_active_job = ExampleJob.perform_later('success')
    running_job = GoodJob::Job.find(running_active_job.provider_job_id)
    running_job.update!(
      performed_at: 1.minute.ago,
      finished_at: nil
    )
  end

  describe '#job_classes' do
    it 'is a valid result' do
      expect(filter.job_classes).to eq({
                                         'ExampleJob' => 5,
                                       })
    end
  end

  describe '#queues' do
    it 'is a valid result' do
      expect(filter.queues).to eq({
                                    "cron" => 1,
                                    "default" => 2,
                                    "elephants" => 1,
                                    "mice" => 1,
                                  })
    end
  end

  describe '#state_names' do
    it 'matches states' do
      expect(filter.state_names).to match_array(filter.states.keys)
    end
  end

  describe '#states' do
    it 'is a valid result' do
      expect(filter.states).to eq({
                                    "scheduled" => 1,
                                    "retried" => 0,
                                    "queued" => 1,
                                    "running" => 1,
                                    "succeeded" => 1,
                                    "discarded" => 1,
                                  })
    end
  end

  describe '#records' do
    it 'is a valid result' do
      expect(filter.records.size).to eq 5
    end

    context 'when filtered by state' do
      before do
        params[:state] = 'running'
      end

      it 'returns a limited set of results' do
        expect(filter.records.size).to eq 1
      end
    end

    context 'when filtered by search' do
      before do
        params[:query] = 'DeadError'
      end

      it 'returns a limited set of results' do
        expect(filter.records.size).to eq 1
      end

      describe 'Ruby namespaced query' do
        before { params[:query] = 'ExampleJob::DeadError' }

        it 'returns a limited set of results' do
          expect(filter.records.size).to eq 1
        end
      end

      describe 'Job ID query' do
        before do
          params[:query] = GoodJob::Job.last.id
        end

        it 'returns the job' do
          expect(filter.records.size).to eq 1
          expect(filter.records.first).to eq GoodJob::Job.last
        end
      end
    end

    context 'when filtered by cron_key' do
      before do
        params[:cron_key] = 'frequent_cron'
      end

      it 'filters results' do
        expect(filter.records.size).to eq 1
      end
    end

    context 'when filtered by finished_since' do
      before do
        GoodJob::Job.find_each { |job| job.update!(finished_at: 6.hours.ago) }
        GoodJob::Job.take.update!(finished_at: 30.minutes.ago)
        params[:finished_since] = '1_hour_ago'
      end

      it 'filters results' do
        expect(filter.records.size).to eq 1
      end
    end
  end

  describe '#filtered_count' do
    it 'returns a count of unlimited items' do
      expect(filter.filtered_count).to eq 5
    end
  end

  %w[
    scheduled
    retried
    queued
    running
    finished
    discarded
  ].each do |filter_state|
    context "with filter state '#{filter_state}'" do
      before do
        params[:state] = filter_state
      end

      it 'returns working results' do
        expect(filter.job_classes).to be_a Hash
        expect(filter.queues).to be_a Hash
        expect(filter.states).to be_a Hash

        expect(filter.records.to_a).to be_an Array
      end
    end
  end
end
