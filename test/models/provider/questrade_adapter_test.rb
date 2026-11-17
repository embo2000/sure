# frozen_string_literal: true

require "test_helper"

class Provider::QuestradeAdapterTest < ActiveSupport::TestCase
  test "returns the historical Questrade choice when the family has no connection" do
    configs = Provider::QuestradeAdapter.connection_configs(family: families(:empty))

    assert_equal 1, configs.length
    assert_equal "questrade", configs.first[:key]
    assert_equal "Questrade", configs.first[:name]
    assert_equal "Connect to your brokerage via Questrade", configs.first[:description]
    assert configs.first[:can_connect]

    uri = URI.parse(configs.first[:new_account_path].call("Investment", "/accounts"))
    assert_equal "/questrade_items/select_accounts", uri.path
    assert_no_match(/questrade_item_id=/, uri.query.to_s)
  end

  test "a single connection still appears as Questrade and is pinned to that connection" do
    family = families(:empty)
    item = family.questrade_items.create!(name: "My Questrade", refresh_token: "solo-token")

    configs = Provider::QuestradeAdapter.connection_configs(family: family)

    assert_equal [ "questrade" ], configs.map { |config| config[:key] }
    assert_equal [ "Questrade" ], configs.map { |config| config[:name] }

    new_account_uri = URI.parse(configs.first[:new_account_path].call("Investment", "/accounts"))
    assert_equal "/questrade_items/select_accounts", new_account_uri.path
    assert_includes new_account_uri.query, "questrade_item_id=#{item.id}"

    existing_account_uri = URI.parse(configs.first[:existing_account_path].call(accounts(:depository).id))
    assert_equal "/questrade_items/select_existing_account", existing_account_uri.path
    assert_includes existing_account_uri.query, "questrade_item_id=#{item.id}"
  end

  test "returns one connection config per questrade login" do
    family = families(:dylan_family)
    mine = questrade_items(:one)
    hers = questrade_items(:requires_update)

    configs = Provider::QuestradeAdapter.connection_configs(family: family)

    assert_equal 2, configs.length
    assert_equal [ "questrade_#{mine.id}", "questrade_#{hers.id}" ].sort, configs.map { |config| config[:key] }.sort
    assert_equal [ mine.name, hers.name ].sort, configs.map { |config| config[:name] }.sort

    configs.each do |config|
      uri = URI.parse(config[:new_account_path].call("Investment", "/accounts"))
      assert_equal "/questrade_items/select_accounts", uri.path
      assert_match(/questrade_item_id=/, uri.query)
    end
  end

  test "connection configs ignore a connection with no refresh token" do
    family = families(:dylan_family)
    questrade_items(:requires_update).update_column(:refresh_token, nil)

    configs = Provider::QuestradeAdapter.connection_configs(family: family)

    assert_equal [ "questrade" ], configs.map { |config| config[:key] }
    assert_includes configs.first[:new_account_path].call("Investment", nil), "questrade_item_id=#{questrade_items(:one).id}"
  end

  test "build_provider uses the requested connection" do
    family = families(:dylan_family)
    hers = questrade_items(:requires_update)

    provider = Provider::QuestradeAdapter.build_provider(family: family, questrade_item_id: hers.id)

    assert_equal hers.refresh_token, provider.refresh_token
  end

  test "build_provider returns nil when several connections exist and none is requested" do
    assert_nil Provider::QuestradeAdapter.build_provider(family: families(:dylan_family))
  end

  test "build_provider returns the only connection when no id is given" do
    family = families(:empty)
    item = family.questrade_items.create!(name: "Only", refresh_token: "only-token")

    provider = Provider::QuestradeAdapter.build_provider(family: family)

    assert_equal item.refresh_token, provider.refresh_token
  end

  test "build_provider refuses a connection from another family" do
    family = families(:empty)
    family.questrade_items.create!(name: "Only", refresh_token: "only-token")

    assert_nil Provider::QuestradeAdapter.build_provider(
      family: family,
      questrade_item_id: questrade_items(:one).id
    )
  end

  test "build_provider returns nil without a family" do
    assert_nil Provider::QuestradeAdapter.build_provider(family: nil)
  end
end
