# frozen_string_literal: true

module Solana::Ruby::Watchtower
  module Stores
    # States as rows of an ActiveRecord model, for running the monitor inside a
    # Rails app. The gem does not depend on Rails; pass in a model whose table
    # has these columns (README has the migration):
    #
    #   key string (unique), alerting boolean, consecutive_failures integer,
    #   failing_since / last_alerted_at / last_checked_at datetime,
    #   last_message text, data json/jsonb
    class ActiveRecordStore
      def initialize(model)
        @model = model
      end

      def fetch(key)
        record = @model.find_by(key: key.to_s)
        return CheckState.new(key: key) unless record

        CheckState.new(**CheckState::ATTRIBUTES.to_h { |attr| [attr, record.public_send(attr)] })
      end

      def save(state)
        record = @model.find_or_initialize_by(key: state.key)
        record.assign_attributes(
          (CheckState::ATTRIBUTES - [:key]).to_h { |attr| [attr, state.public_send(attr)] }
        )
        record.save!
      end

      def all = @model.order(:key).map { |record| fetch(record.key) }
    end
  end
end
