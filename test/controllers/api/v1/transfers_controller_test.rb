# frozen_string_literal: true

require "test_helper"

class Api::V1::TransfersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @user.api_keys.active.destroy_all

    @api_key = ApiKey.create!(
      user: @user,
      name: "Test Read Key",
      scopes: [ "read" ],
      source: "web",
      display_key: "test_read_#{SecureRandom.hex(8)}"
    )

    @account = @family.accounts.create!(
      name: "Transfer Checking",
      accountable: Depository.new,
      balance: 500,
      currency: "USD"
    )
    @destination_account = @family.accounts.create!(
      name: "Transfer Savings",
      accountable: Depository.new,
      balance: 1000,
      currency: "USD"
    )

    outflow = create_transaction(@account, amount: 100, date: Date.parse("2024-01-15"), name: "Transfer to savings")
    inflow = create_transaction(@destination_account, amount: -100, date: Date.parse("2024-01-15"), name: "Transfer from checking")
    @transfer = Transfer.create!(
      outflow_transaction: outflow,
      inflow_transaction: inflow,
      status: "confirmed",
      notes: "Confirmed by user"
    )

    other_family = families(:empty)
    other_account = other_family.accounts.create!(name: "Other Checking", accountable: Depository.new, balance: 0, currency: "USD")
    other_destination = other_family.accounts.create!(name: "Other Savings", accountable: Depository.new, balance: 0, currency: "USD")
    other_outflow = create_transaction(other_account, amount: 50, date: Date.parse("2024-01-15"), name: "Other outflow")
    other_inflow = create_transaction(other_destination, amount: -50, date: Date.parse("2024-01-15"), name: "Other inflow")
    @other_transfer = Transfer.create!(outflow_transaction: other_outflow, inflow_transaction: other_inflow)
  end

  test "lists transfers scoped to the current family" do
    get api_v1_transfers_url, headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert response_data.key?("transfers")
    assert response_data.key?("pagination")
    assert_includes response_data["transfers"].map { |transfer| transfer["id"] }, @transfer.id
    assert_not_includes response_data["transfers"].map { |transfer| transfer["id"] }, @other_transfer.id
  end

  test "permits read write scope" do
    read_write_key = ApiKey.create!(
      user: @user,
      name: "Test Read Write Key",
      scopes: [ "read_write" ],
      source: "mobile",
      display_key: "test_read_write_#{SecureRandom.hex(8)}"
    )

    get api_v1_transfers_url, headers: api_headers(read_write_key)

    assert_response :success
  end

  test "shows a transfer" do
    get api_v1_transfer_url(@transfer), headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal @transfer.id, response_data["id"]
    assert_equal "confirmed", response_data["status"]
    assert_equal "Confirmed by user", response_data["notes"]
    assert_equal "Transfer Savings", response_data.dig("inflow_transaction", "account", "name")
    assert_equal "Transfer Checking", response_data.dig("outflow_transaction", "account", "name")
    assert response_data.key?("amount_cents")
    assert_equal "0.0", response_data["source_fee_amount"]
    assert_equal "0.0", response_data["destination_fee_amount"]
    assert response_data.key?("source_fee_currency")
    assert response_data.key?("destination_fee_currency")
  end

  test "returns not found for another family's transfer" do
    get api_v1_transfer_url(@other_transfer), headers: api_headers(@api_key)

    assert_response :not_found
    response_data = JSON.parse(response.body)
    assert_equal "record_not_found", response_data["error"]
  end

  test "returns not found for malformed transfer id" do
    get api_v1_transfer_url("not-a-uuid"), headers: api_headers(@api_key)

    assert_response :not_found
    response_data = JSON.parse(response.body)
    assert_equal "record_not_found", response_data["error"]
  end

  test "filters transfers by status" do
    get api_v1_transfers_url, params: { status: "confirmed" }, headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal [ @transfer.id ], response_data["transfers"].map { |transfer| transfer["id"] }
  end

  test "filters transfers by account_id" do
    get api_v1_transfers_url, params: { account_id: @account.id }, headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_includes response_data["transfers"].map { |transfer| transfer["id"] }, @transfer.id
  end

  test "rejects malformed account_id filter" do
    get api_v1_transfers_url, params: { account_id: "not-a-uuid" }, headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
  end

  test "rejects invalid status filter" do
    get api_v1_transfers_url, params: { status: "settled" }, headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
  end

  test "rejects invalid date filter" do
    get api_v1_transfers_url, params: { start_date: "01/15/2024" }, headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
  end

  test "filters transfers when either transaction side date matches" do
    matched_outflow = create_transaction(@account, amount: 75, date: Date.parse("2024-02-10"), name: "Dated outflow")
    matched_inflow = create_transaction(@destination_account, amount: -75, date: Date.parse("2024-02-10"), name: "Dated inflow")
    date_matched_transfer = Transfer.create!(outflow_transaction: matched_outflow, inflow_transaction: matched_inflow)

    partial_outflow = create_transaction(@account, amount: 80, date: Date.parse("2024-02-10"), name: "Partial outflow")
    partial_inflow = create_transaction(@destination_account, amount: -80, date: Date.parse("2024-02-12"), name: "Partial inflow")
    partial_date_transfer = Transfer.create!(outflow_transaction: partial_outflow, inflow_transaction: partial_inflow)

    get api_v1_transfers_url,
        params: { start_date: "2024-02-10", end_date: "2024-02-10" },
        headers: api_headers(@api_key)

    assert_response :success
    transfer_ids = JSON.parse(response.body)["transfers"].map { |transfer| transfer["id"] }
    assert_includes transfer_ids, date_matched_transfer.id
    assert_includes transfer_ids, partial_date_transfer.id
    assert_not_includes transfer_ids, @transfer.id
  end

  test "matches two existing transactions as a confirmed transfer" do
    outflow = create_transaction(@account, amount: 40, date: Date.current, name: "To savings")
    inflow = create_transaction(@destination_account, amount: -40, date: Date.current, name: "From checking")

    assert_difference "Transfer.count", 1 do
      post api_v1_transfers_url,
           params: { transfer: { outflow_transaction_id: outflow.id, inflow_transaction_id: inflow.id } },
           headers: api_headers(read_write_key),
           as: :json
    end

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal "confirmed", body["status"]
    assert_equal outflow.id, body.dig("outflow_transaction", "id")
    assert_equal inflow.id, body.dig("inflow_transaction", "id")
    assert_equal "funds_movement", outflow.reload.kind
    assert_equal "funds_movement", inflow.reload.kind
    assert_equal "funds_movement", body.dig("outflow_transaction", "kind")
  end

  test "matches a pair when the ids are given in either order" do
    outflow = create_transaction(@account, amount: 15, date: Date.current, name: "Payment")
    inflow = create_transaction(@destination_account, amount: -15, date: Date.current, name: "Deposit")

    post api_v1_transfers_url,
         params: { transfer: { outflow_transaction_id: inflow.id, inflow_transaction_id: outflow.id } },
         headers: api_headers(read_write_key),
         as: :json

    assert_response :created
    transfer = Transfer.find(JSON.parse(response.body)["id"])
    assert_equal inflow, transfer.inflow_transaction
    assert_equal outflow, transfer.outflow_transaction
  end

  test "rejects a transfer pair on the same account" do
    outflow = create_transaction(@account, amount: 20, date: Date.current, name: "Out")
    inflow = create_transaction(@account, amount: -20, date: Date.current, name: "In")

    assert_no_difference "Transfer.count" do
      post api_v1_transfers_url,
           params: { transfer: { outflow_transaction_id: outflow.id, inflow_transaction_id: inflow.id } },
           headers: api_headers(read_write_key),
           as: :json
    end

    assert_response :unprocessable_entity
    assert_equal "validation_failed", JSON.parse(response.body)["error"]
  end

  test "rejects a transfer pair whose dates are too far apart" do
    outflow = create_transaction(@account, amount: 20, date: Date.current, name: "Out")
    inflow = create_transaction(@destination_account, amount: -20, date: Date.current - 45.days, name: "In")

    assert_no_difference "Transfer.count" do
      post api_v1_transfers_url,
           params: { transfer: { outflow_transaction_id: outflow.id, inflow_transaction_id: inflow.id } },
           headers: api_headers(read_write_key),
           as: :json
    end

    assert_response :unprocessable_entity
  end

  test "rejects a transfer pair from another family" do
    foreign_outflow = @other_transfer.outflow_transaction
    inflow = create_transaction(@destination_account, amount: -50, date: Date.parse("2024-01-15"), name: "Local inflow")

    assert_no_difference "Transfer.count" do
      post api_v1_transfers_url,
           params: { transfer: { outflow_transaction_id: foreign_outflow.id, inflow_transaction_id: inflow.id } },
           headers: api_headers(read_write_key),
           as: :json
    end

    assert_response :not_found
  end

  test "refuses to match transactions with a read-only key" do
    outflow = create_transaction(@account, amount: 11, date: Date.current, name: "Out")
    inflow = create_transaction(@destination_account, amount: -11, date: Date.current, name: "In")

    assert_no_difference "Transfer.count" do
      post api_v1_transfers_url,
           params: { transfer: { outflow_transaction_id: outflow.id, inflow_transaction_id: inflow.id } },
           headers: api_headers(@api_key),
           as: :json
    end

    assert_response :forbidden
  end

  test "unmatches a transfer and keeps both transactions" do
    outflow = @transfer.outflow_transaction
    inflow = @transfer.inflow_transaction

    assert_difference -> { Transfer.count } => -1, -> { RejectedTransfer.count } => 1, -> { Transaction.count } => 0 do
      delete api_v1_transfer_url(@transfer), headers: api_headers(read_write_key)
    end

    assert_response :success
    assert_not Transfer.exists?(@transfer.id)
    assert Transaction.exists?(outflow.id)
    assert Transaction.exists?(inflow.id)
    assert_equal "standard", outflow.reload.kind
    assert_equal "standard", inflow.reload.kind
    assert RejectedTransfer.exists?(inflow_transaction_id: inflow.id, outflow_transaction_id: outflow.id)
  end

  test "refuses to unmatch a transfer with a read-only key" do
    assert_no_difference [ "Transfer.count", "RejectedTransfer.count" ] do
      delete api_v1_transfer_url(@transfer), headers: api_headers(@api_key)
    end

    assert_response :forbidden
    assert Transfer.exists?(@transfer.id)
  end

  test "requires authentication" do
    get api_v1_transfers_url

    assert_response :unauthorized
  end

  test "requires read scope" do
    # ApiKey.create! rejects empty scopes; bypass validation to exercise runtime authorization.
    api_key_without_read = ApiKey.new(
      user: @user,
      name: "No Read Key",
      scopes: [],
      source: "mobile",
      display_key: "no_read_#{SecureRandom.hex(8)}"
    )
    api_key_without_read.save!(validate: false)

    get api_v1_transfers_url, headers: api_headers(api_key_without_read)

    assert_response :forbidden
  ensure
    api_key_without_read&.destroy
  end

  private

    def create_transaction(account, amount:, date:, name:)
      entry = account.entries.create!(
        date: date,
        amount: amount,
        name: name,
        currency: account.currency,
        entryable: Transaction.new(kind: "funds_movement")
      )
      entry.entryable
    end

    def api_headers(api_key)
      { "X-Api-Key" => api_key.display_key }
    end

    def read_write_key
      @read_write_key ||= ApiKey.create!(
        user: @user,
        name: "Transfer Write Key",
        scopes: [ "read_write" ],
        source: "mobile",
        display_key: "test_transfer_rw_#{SecureRandom.hex(8)}"
      )
    end
end
