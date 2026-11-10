# frozen_string_literal: true

class Api::V1::TransfersController < Api::V1::BaseController
  include Pagy::Backend
  include Api::V1::TransferDecisionFiltering

  before_action :ensure_read_scope
  before_action :ensure_write_scope, only: [ :create, :destroy ]
  before_action :set_transfer, only: [ :show, :destroy ]

  def index
    transfers_query = apply_transfer_decision_filters(transfers_scope, status_model: Transfer).order(created_at: :desc)
    @per_page = safe_per_page_param

    @pagy, @transfers = pagy(
      transfers_query,
      page: safe_page_param,
      limit: @per_page
    )

    render :index
  rescue Api::V1::TransferDecisionFiltering::InvalidFilterError => e
    render_validation_error(e.message)
  end

  def show
    render :show
  end

  # Match two existing transactions. Inflow and outflow follow the entry
  # amount signs, the same way the transfer-match dialog does, then
  # Transfer#confirm! sets the budget kinds.
  def create
    first, second = transfer_legs
    return if performed?

    inflow, outflow = ordered_transfer_pair(first, second)
    return render_transfer_forbidden unless transfer_accounts_writable?([ inflow, outflow ])

    @transfer = Transfer.find_or_initialize_by(inflow_transaction: inflow, outflow_transaction: outflow)
    new_match = @transfer.new_record?
    @transfer.status = "confirmed"

    Transfer.transaction do
      @transfer.save!
      @transfer.confirm!
    end
    @transfer.sync_account_later

    render :show, status: new_match ? :created : :ok
  rescue ActiveRecord::RecordInvalid => e
    render_transfer_invalid(e.record)
  end

  # Remove the link the way the UI rejects a match: both transactions stay,
  # a confirmed match's kinds return to standard, and the pair is remembered
  # so automatic matching does not put it back.
  def destroy
    return render_transfer_forbidden unless transfer_unmatch_allowed?(@transfer)

    inflow_transaction_id = @transfer.inflow_transaction_id
    outflow_transaction_id = @transfer.outflow_transaction_id
    @transfer.reject!

    render json: {
      message: "Transfer removed",
      inflow_transaction_id: inflow_transaction_id,
      outflow_transaction_id: outflow_transaction_id
    }
  end

  private

    def set_transfer
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      @transfer = transfers_scope.find(params[:id])
    end

    def transfers_scope
      transfer_decision_scope(Transfer)
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def transfer_params
      params.require(:transfer).permit(:inflow_transaction_id, :outflow_transaction_id)
    end

    def transfer_legs
      [ transfer_params[:inflow_transaction_id], transfer_params[:outflow_transaction_id] ].map do |id|
        find_accessible_transaction!(id)
      end
    rescue ActiveRecord::RecordNotFound
      render json: { error: "not_found", message: "Transaction not found" }, status: :not_found
      nil
    end

    def find_accessible_transaction!(id)
      raise ActiveRecord::RecordNotFound unless self.class.valid_uuid?(id)

      current_resource_owner.family.transactions
        .joins(entry: :account)
        .merge(Account.accessible_by(current_resource_owner))
        .find(id)
    end

    def ordered_transfer_pair(first, second)
      inflow = [ first, second ].find { |transaction| transaction.entry.amount.negative? }
      outflow = [ first, second ].find { |transaction| transaction.entry.amount.positive? }
      return [ inflow, outflow ] if inflow && outflow && inflow != outflow

      [ first, second ]
    end

    def transfer_accounts_writable?(transactions)
      account_ids = transactions.map { |transaction| transaction.entry.account_id }.uniq
      writable_ids = writable_account_ids(account_ids)
      account_ids.all? { |id| writable_ids.include?(id) }
    end

    # Unlinking needs a writable endpoint, and every fee account, because
    # removing the transfer deletes its fee transactions.
    def transfer_unmatch_allowed?(transfer)
      endpoints = [ transfer.from_account, transfer.to_account ].compact
      fee_accounts = Account.where(id: transfer.fee_transactions.joins(:entry).select("entries.account_id")).to_a
      writable_ids = writable_account_ids((endpoints + fee_accounts).map(&:id))

      endpoints.any? { |account| writable_ids.include?(account.id) } &&
        fee_accounts.all? { |account| writable_ids.include?(account.id) }
    end

    def writable_account_ids(ids)
      current_resource_owner.family.accounts.writable_by(current_resource_owner).where(id: ids).pluck(:id).to_set
    end

    def render_transfer_forbidden
      render json: { error: "forbidden", message: "You do not have permission to modify these accounts" }, status: :forbidden
    end

    def render_transfer_invalid(record)
      render json: {
        error: "validation_failed",
        message: "Transfer could not be matched",
        errors: record.errors.full_messages
      }, status: :unprocessable_entity
    end
end
