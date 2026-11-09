require "test_helper"
require "ostruct"

class PlaidItem::ImporterTest < ActiveSupport::TestCase
  setup do
    @mock_provider = mock("Provider::Plaid")
    @plaid_item = plaid_items(:one)
    @importer = PlaidItem::Importer.new(@plaid_item, plaid_provider: @mock_provider)
  end

  test "imports item metadata" do
    item_data = OpenStruct.new(
      item_id: "item_1",
      available_products: [ "transactions", "investments", "liabilities" ],
      billed_products: [],
      institution_id: "ins_1",
      institution_name: "First Platypus Bank",
    )

    @mock_provider.expects(:get_item).with(@plaid_item.access_token).returns(
      OpenStruct.new(item: item_data)
    )

    institution_data = OpenStruct.new(
      institution_id: "ins_1",
      institution_name: "First Platypus Bank",
    )

    @mock_provider.expects(:get_institution).with("ins_1").returns(
      OpenStruct.new(institution: institution_data)
    )

    PlaidItem::AccountsSnapshot.any_instance.expects(:accounts).returns([
      OpenStruct.new(
        account_id: "acc_1",
        type: "depository",
      )
    ]).at_least_once

    PlaidItem::AccountsSnapshot.any_instance.expects(:transactions_cursor).returns("test_cursor_1")

    PlaidItem::AccountsSnapshot.any_instance.expects(:get_account_data).with("acc_1").once

    PlaidAccount::Importer.any_instance.expects(:import).once

    @plaid_item.expects(:update!).with(next_cursor: "test_cursor_1")
    @plaid_item.expects(:upsert_plaid_snapshot!).with(item_data)
    @plaid_item.expects(:upsert_plaid_institution_snapshot!).with(institution_data)

    @importer.import
  end

  test "clears requires update status after a successful import" do
    @plaid_item.update!(status: :requires_update)
    @importer.stubs(:fetch_and_import_item_data)
    @importer.stubs(:fetch_and_import_accounts_data)

    @importer.import

    assert_predicate @plaid_item.reload, :good?
  end

  test "keeps requires update status when login is still required" do
    @plaid_item.update!(status: :requires_update)
    error = Plaid::ApiError.new(
      code: 400,
      response_body: { "error_code" => "ITEM_LOGIN_REQUIRED" }.to_json
    )
    @importer.stubs(:fetch_and_import_item_data).raises(error)
    @importer.expects(:fetch_and_import_accounts_data).never

    @importer.import

    assert_predicate @plaid_item.reload, :requires_update?
  end

  test "imports banking accounts when unbilled investments are not supported" do
    @plaid_item.update!(
      status: :good,
      billed_products: [ "transactions" ],
      available_products: [],
      raw_payload: { "consented_products" => [ "transactions", "investments" ] },
      next_cursor: nil
    )
    @plaid_item.plaid_accounts.destroy_all
    @importer.stubs(:fetch_and_import_item_data)

    checking = account_payload("chk_1", "Chequing", "depository", "checking")
    tfsa = account_payload("inv_1", "TFSA", "investment", "tfsa")
    @mock_provider.expects(:get_item_accounts).with(@plaid_item.access_token).returns(
      OpenStruct.new(accounts: [ checking, tfsa ])
    )
    @mock_provider.expects(:get_transactions).with(@plaid_item.access_token, next_cursor: nil).returns(
      OpenStruct.new(
        added: [ OpenStruct.new(account_id: "chk_1", transaction_id: "tx_1", amount: 12.5) ],
        modified: [],
        removed: [],
        cursor: "cursor_after"
      )
    )
    @mock_provider.expects(:get_item_investments).with(@plaid_item.access_token).raises(
      Plaid::ApiError.new(code: 400, response_body: {
        "error_type" => "ITEM_ERROR",
        "error_code" => "PRODUCTS_NOT_SUPPORTED",
        "error_message" => 'The following products are not supported by this institution: ["investments"]'
      }.to_json)
    ).once

    @importer.import

    @plaid_item.reload
    assert_predicate @plaid_item, :good?
    assert_equal "cursor_after", @plaid_item.next_cursor

    chequing = @plaid_item.plaid_accounts.find_by!(plaid_id: "chk_1")
    assert_equal "Chequing", chequing.name
    assert_equal "depository", chequing.plaid_type
    assert_includes chequing.raw_transactions_payload.to_json, "tx_1"

    investment = @plaid_item.plaid_accounts.find_by!(plaid_id: "inv_1")
    assert_equal "investment", investment.plaid_type
    assert_equal({}, investment.raw_holdings_payload)
  end

  test "does not keep accounts when an unbilled investments call requires login" do
    @plaid_item.update!(
      status: :good,
      billed_products: [ "transactions" ],
      available_products: [],
      raw_payload: { "consented_products" => [ "transactions", "investments" ] },
      next_cursor: nil
    )
    @plaid_item.plaid_accounts.destroy_all
    @importer.stubs(:fetch_and_import_item_data)
    @mock_provider.stubs(:get_item_accounts).returns(
      OpenStruct.new(accounts: [ account_payload("inv_1", "TFSA", "investment", "tfsa") ])
    )
    @mock_provider.stubs(:get_transactions).returns(
      OpenStruct.new(added: [], modified: [], removed: [], cursor: "cursor_after")
    )
    @mock_provider.expects(:get_item_investments).raises(
      Plaid::ApiError.new(code: 400, response_body: { "error_code" => "ITEM_LOGIN_REQUIRED" }.to_json)
    )

    @importer.import

    assert_predicate @plaid_item.reload, :requires_update?
    assert_empty @plaid_item.plaid_accounts
    assert_nil @plaid_item.next_cursor
  end

  test "does not import accounts when billed investments are not supported" do
    @plaid_item.update!(
      status: :good,
      billed_products: [ "investments" ],
      available_products: [],
      raw_payload: { "consented_products" => [ "investments" ] },
      next_cursor: nil
    )
    @plaid_item.plaid_accounts.destroy_all
    @importer.stubs(:fetch_and_import_item_data)
    @mock_provider.stubs(:get_item_accounts).returns(
      OpenStruct.new(accounts: [ account_payload("inv_1", "TFSA", "investment", "tfsa") ])
    )
    @mock_provider.expects(:get_item_investments).raises(
      Plaid::ApiError.new(code: 400, response_body: { "error_code" => "PRODUCTS_NOT_SUPPORTED" }.to_json)
    )

    assert_raises(Plaid::ApiError) { @importer.import }

    assert_empty @plaid_item.reload.plaid_accounts
    assert_nil @plaid_item.next_cursor
    assert_predicate @plaid_item, :good?
  end

  private
    def account_payload(id, name, type, subtype)
      OpenStruct.new(
        account_id: id,
        name: name,
        type: type,
        subtype: subtype,
        mask: "0000",
        balances: OpenStruct.new(current: 10.0, available: 10.0, iso_currency_code: "CAD")
      )
    end
end
