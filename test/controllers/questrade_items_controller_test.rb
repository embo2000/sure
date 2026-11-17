# frozen_string_literal: true

require "test_helper"

class QuestradeItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    SyncJob.stubs(:perform_later)

    @family = families(:dylan_family)
    @questrade_item = questrade_items(:one)
  end

  # ---------------------------------------------------------------------------
  # create
  # ---------------------------------------------------------------------------

  test "create adds a new questrade connection" do
    assert_difference "QuestradeItem.count", 1 do
      post questrade_items_url, params: {
        questrade_item: { name: "Business Questrade", refresh_token: "new_token_abc" }
      }
    end

    assert_redirected_to settings_providers_path
    assert_equal "new_token_abc", @family.questrade_items.find_by!(name: "Business Questrade").refresh_token
  end

  test "create uses localized default name when submitted name is blank" do
    assert_difference "QuestradeItem.count", 1 do
      post questrade_items_url, params: {
        questrade_item: { name: "  ", refresh_token: "default_name_token" }
      }
    end

    assert_redirected_to settings_providers_path
    assert_equal I18n.t("questrade_items.default_name"), @family.questrade_items.order(:created_at).last.name
  end

  test "invalid create from the page shows the error in the panel" do
    post questrade_items_url,
         params: { questrade_item: { name: "Business Questrade", refresh_token: "" } },
         as: :turbo_stream

    assert_turbo_stream status: :unprocessable_entity, action: "replace", target: "questrade-providers-panel"
    assert_includes response.body, ERB::Util.html_escape("Refresh token can't be blank")
  end

  # ---------------------------------------------------------------------------
  # update
  # ---------------------------------------------------------------------------

  test "update renames item and resets status to good when new token provided" do
    @questrade_item.update!(status: :requires_update)

    patch questrade_item_url(@questrade_item), params: {
      questrade_item: { name: "Renamed Questrade", refresh_token: "refreshed_token" }
    }

    @questrade_item.reload
    assert_redirected_to settings_providers_path
    assert_equal "Renamed Questrade", @questrade_item.name
    assert_equal "refreshed_token", @questrade_item.refresh_token
    assert_equal "good", @questrade_item.status
  end

  test "update with blank token preserves existing token" do
    original_token = @questrade_item.refresh_token

    patch questrade_item_url(@questrade_item), params: {
      questrade_item: { name: "Renamed Questrade", refresh_token: "" }
    }

    @questrade_item.reload
    assert_redirected_to settings_providers_path
    assert_equal "Renamed Questrade", @questrade_item.name
    assert_equal original_token, @questrade_item.refresh_token
  end

  # Redirecting back to Bank sync collapses the open connection row.
  test "update from the page re-renders the panel in place" do
    patch questrade_item_url(@questrade_item),
          params: { questrade_item: { name: "Renamed Questrade", refresh_token: "" } },
          as: :turbo_stream

    assert_turbo_stream action: "replace", target: "questrade-providers-panel"
    assert_includes response.body, %(id="questrade-providers-panel")
    assert_includes response.body, "Renamed Questrade"
    assert_includes response.body, questrade_items(:requires_update).name
    assert_includes response.body, questrade_items_path
    assert_equal "Renamed Questrade", @questrade_item.reload.name
  end

  test "updating one connection does not replace the other token" do
    other = questrade_items(:requires_update)
    original_token = other.refresh_token

    patch questrade_item_url(@questrade_item), params: {
      questrade_item: { name: "Renamed Questrade", refresh_token: "only-this-connection" }
    }

    assert_equal "only-this-connection", @questrade_item.reload.refresh_token
    assert_equal "good", @questrade_item.status
    assert_equal original_token, other.reload.refresh_token
    assert_equal "requires_update", other.status
    assert_equal "Stale Questrade", other.name
  end

  test "creating another connection keeps the existing token" do
    original_token = @questrade_item.refresh_token

    assert_difference "QuestradeItem.count", 1 do
      post questrade_items_url, params: {
        questrade_item: { name: "Jane's Questrade", refresh_token: "jane-token" }
      }
    end

    created = @family.questrade_items.find_by!(name: "Jane's Questrade")
    assert_equal "jane-token", created.refresh_token
    assert_equal original_token, @questrade_item.reload.refresh_token
  end

  # ---------------------------------------------------------------------------
  # destroy
  # ---------------------------------------------------------------------------

  test "destroy schedules the item for deletion" do
    delete questrade_item_url(@questrade_item)

    assert_redirected_to settings_providers_path
    assert @questrade_item.reload.scheduled_for_deletion?
    assert_not questrade_items(:requires_update).reload.scheduled_for_deletion?
  end

  # ---------------------------------------------------------------------------
  # sync
  # ---------------------------------------------------------------------------

  test "sync enqueues a sync job" do
    other = questrade_items(:requires_update)

    assert_difference -> { Sync.where(syncable: @questrade_item).count }, 1 do
      assert_no_difference -> { Sync.where(syncable: other).count } do
        post sync_questrade_item_url(@questrade_item)
      end
    end

    assert_response :redirect
  end

  test "sync is a no-op when item is already syncing" do
    @questrade_item.syncs.create!(status: :syncing)

    assert_no_difference -> { Sync.where(syncable: @questrade_item).count } do
      post sync_questrade_item_url(@questrade_item)
    end

    assert_response :redirect
  end

  # ---------------------------------------------------------------------------
  # select_accounts / link_accounts
  # ---------------------------------------------------------------------------

  test "select_accounts redirects to setup_accounts when only one connection is configured" do
    questrade_items(:requires_update).update_column(:refresh_token, nil)

    get select_accounts_questrade_items_url

    assert_redirected_to setup_accounts_questrade_item_url(@questrade_item)
  end

  test "select_accounts redirects to settings when credentials not configured" do
    @family.questrade_items.update_all(refresh_token: nil)

    get select_accounts_questrade_items_url

    assert_redirected_to settings_providers_path
  end

  test "select_accounts opens the requested connection when several exist" do
    mine = questrade_items(:one)
    hers = questrade_items(:requires_update)

    get select_accounts_questrade_items_url(questrade_item_id: hers.id)
    assert_redirected_to setup_accounts_questrade_item_url(hers)

    get select_accounts_questrade_items_url(questrade_item_id: mine.id)
    assert_redirected_to setup_accounts_questrade_item_url(mine)
  end

  test "select_accounts asks which connection to set up when several exist" do
    get select_accounts_questrade_items_url

    assert_response :success
    assert_includes response.body, questrade_items(:one).name
    assert_includes response.body, questrade_items(:requires_update).name
    assert_includes response.body, setup_accounts_questrade_item_path(questrade_items(:one))
    assert_includes response.body, setup_accounts_questrade_item_path(questrade_items(:requires_update))
  end

  test "select_accounts ignores a connection from another family" do
    other = families(:empty).questrade_items.create!(name: "Other family", refresh_token: "other-token")

    get select_accounts_questrade_items_url(questrade_item_id: other.id)

    assert_redirected_to settings_providers_path
    assert_not_includes response.location, other.id
  end

  test "link_accounts creates new accounts for selected questrade_accounts" do
    questrade_account = @questrade_item.questrade_accounts.create!(
      name: "RRSP (87654321)",
      questrade_account_id: "87654321",
      account_type: "RRSP",
      currency: "CAD",
      current_balance: 5000
    )

    assert_difference "Account.count", 1 do
      assert_difference "AccountProvider.count", 1 do
        post link_accounts_questrade_items_url, params: {
          selected_account_ids: [ questrade_account.id ],
          accountable_type: "Investment"
        }
      end
    end

    assert_redirected_to accounts_path
  end

  test "link_accounts redirects to settings when no credentials configured" do
    @family.questrade_items.update_all(refresh_token: nil)

    post link_accounts_questrade_items_url, params: {
      selected_account_ids: [ 999 ]
    }

    assert_redirected_to settings_providers_path
  end

  test "link_accounts links the requested connection and leaves the other alone" do
    hers = questrade_items(:requires_update)
    hers_account = create_questrade_account(hers, "87654322")
    mine_account = create_questrade_account(@questrade_item, "87654323")

    assert_difference "Account.count", 1 do
      post link_accounts_questrade_items_url, params: {
        questrade_item_id: hers.id,
        selected_account_ids: [ hers_account.id ],
        accountable_type: "Investment"
      }
    end

    assert_redirected_to accounts_path
    assert hers_account.reload.account_provider.present?
    assert_equal hers, hers_account.questrade_item
    assert_nil mine_account.reload.account_provider
  end

  test "link_accounts redirects when no account ids selected" do
    post link_accounts_questrade_items_url, params: { selected_account_ids: [] }

    assert_redirected_to select_accounts_questrade_items_url
  end

  # ---------------------------------------------------------------------------
  # setup_accounts / complete_account_setup
  # ---------------------------------------------------------------------------

  test "setup_accounts renders unlinked accounts" do
    get setup_accounts_questrade_item_url(@questrade_item)

    assert_response :success
  end

  test "complete_account_setup creates accounts from config and redirects" do
    questrade_account = @questrade_item.questrade_accounts.create!(
      name: "Margin (11111111)",
      questrade_account_id: "11111111",
      account_type: "Margin",
      currency: "CAD",
      current_balance: 3000
    )

    assert_difference "Account.count", 1 do
      post complete_account_setup_questrade_item_url(@questrade_item), params: {
        accounts: {
          questrade_account.id.to_s => { account_type: "investment", balance: "3000" }
        }
      }
    end

    assert_redirected_to accounts_path
  end

  test "complete_account_setup redirects with alert when no accounts provided" do
    post complete_account_setup_questrade_item_url(@questrade_item), params: { accounts: {} }

    assert_redirected_to setup_accounts_questrade_item_url(@questrade_item)
  end

  test "complete_account_setup does not import an account from another connection" do
    foreign = create_questrade_account(questrade_items(:requires_update), "99990000")

    assert_no_difference "Account.count" do
      assert_no_difference -> { Sync.where(syncable: questrade_items(:requires_update)).count } do
        post complete_account_setup_questrade_item_url(@questrade_item), params: {
          accounts: { foreign.id => { account_type: "investment", balance: "10" } }
        }
      end
    end

    assert_nil foreign.reload.account_provider
  end

  test "link_existing_account syncs the connection that owns the brokerage account" do
    hers = questrade_items(:requires_update)
    hers_account = create_questrade_account(hers, "55550000")
    sure_account = @family.accounts.create!(
      name: "Unlinked TFSA",
      balance: 0,
      currency: "CAD",
      accountable: Investment.new
    )

    assert_difference -> { Sync.where(syncable: hers).count }, 1 do
      assert_no_difference -> { Sync.where(syncable: @questrade_item).count } do
        post link_existing_account_questrade_items_url, params: {
          account_id: sure_account.id,
          questrade_account_id: hers_account.id,
          questrade_item_id: hers.id
        }
      end
    end

    assert_redirected_to account_path(sure_account)
    assert_equal sure_account, hers_account.reload.account
  end

  test "link_existing_account refuses a brokerage account from another family" do
    other_item = families(:empty).questrade_items.create!(name: "Other", refresh_token: "other-token")
    other_account = create_questrade_account(other_item, "44440000")
    sure_account = @family.accounts.create!(
      name: "Still manual",
      balance: 0,
      currency: "CAD",
      accountable: Investment.new
    )

    post link_existing_account_questrade_items_url, params: {
      account_id: sure_account.id,
      questrade_account_id: other_account.id
    }

    assert_response :not_found
    assert_nil other_account.reload.account_provider
  end

  test "bank sync lists every questrade connection and a form to add another" do
    ensure_tailwind_build

    get settings_providers_url

    assert_response :success
    assert_select "form[action=?]", questrade_item_path(questrade_items(:one))
    assert_select "form[action=?]", questrade_item_path(questrade_items(:requires_update))
    assert_select "form[action=?]", questrade_items_path
    assert_select "form[action=?]", sync_questrade_item_path(questrade_items(:one))
    assert_select "form[action=?]", sync_questrade_item_path(questrade_items(:requires_update))
    assert_select "input[name='questrade_item[name]']"
    assert_includes response.body, "My Questrade"
    assert_includes response.body, "Stale Questrade"
    assert_includes response.body, I18n.t("questrade_items.panel.add_connection")
  end

  # ---------------------------------------------------------------------------
  # admin guard
  # ---------------------------------------------------------------------------

  test "non-admin cannot create a questrade item" do
    sign_in users(:family_member)

    assert_no_difference "QuestradeItem.count" do
      post questrade_items_url, params: {
        questrade_item: { name: "Sneaky Questrade", refresh_token: "sneak_token" }
      }
    end

    assert_redirected_to accounts_path
  end

  test "non-admin cannot destroy a questrade item" do
    sign_in users(:family_member)

    delete questrade_item_url(@questrade_item)

    assert_redirected_to accounts_path
    assert_not @questrade_item.reload.scheduled_for_deletion?
  end

  private
    def create_questrade_account(item, number)
      item.questrade_accounts.create!(
        name: "TFSA (#{number})",
        questrade_account_id: number,
        account_type: "TFSA",
        currency: "CAD",
        current_balance: 100
      )
    end
end
