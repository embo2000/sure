# frozen_string_literal: true

require "test_helper"
require "ostruct"

class QuestradeItemTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @mine = questrade_items(:one)
    @hers = questrade_items(:requires_update)
  end

  test "a family can keep two live connections" do
    assert_equal 2, @family.questrade_items.credentialed.count
    assert_equal [ @mine, @hers ].sort_by(&:id), @family.questrade_items.syncable.sort_by(&:id)
  end

  test "rotating one connection's refresh token leaves the other connection unchanged" do
    @mine.update!(refresh_token: "mine-token", api_server: "https://api01.example.com")
    @hers.update!(refresh_token: "hers-token", api_server: "https://api02.example.com")

    payload = {
      access_token: "access-123",
      api_server: "https://api02.example.com/",
      refresh_token: "hers-rotated",
      expires_in: 1800
    }.to_json
    Provider::Questrade.stubs(:post).returns(OpenStruct.new(code: 200, body: payload))

    @hers.questrade_provider.send(:authenticate!)

    assert_equal "hers-rotated", @hers.reload.refresh_token
    assert_equal "https://api02.example.com/", @hers.api_server
    assert_equal "mine-token", @mine.reload.refresh_token
    assert_equal "https://api01.example.com", @mine.api_server
  end

  test "unlink_all! detaches only this connection's accounts" do
    family = families(:empty)
    mine = family.questrade_items.create!(name: "Mine", refresh_token: "mine-token")
    hers = family.questrade_items.create!(name: "Hers", refresh_token: "hers-token")
    mine_link = link_brokerage_account(mine, "11112222")
    hers_link = link_brokerage_account(hers, "33334444")

    mine.unlink_all!

    assert_nil mine_link.reload.account_provider
    assert hers_link.reload.account_provider.present?
    assert_equal "Hers", hers.reload.name
    assert_equal "hers-token", hers.refresh_token
  end

  test "destroying one connection unlinks only its accounts and keeps the Sure accounts" do
    family = families(:empty)
    mine = family.questrade_items.create!(name: "Mine", refresh_token: "mine-token")
    hers = family.questrade_items.create!(name: "Hers", refresh_token: "hers-token")
    mine_link = link_brokerage_account(mine, "11112222")
    hers_link = link_brokerage_account(hers, "33334444")
    mine_sure = mine_link.account
    hers_sure = hers_link.account

    hers.destroy!

    assert_not QuestradeItem.exists?(hers.id)
    assert_not QuestradeAccount.exists?(hers_link.id)
    assert_nil hers_sure.reload.account_providers.find_by(provider_type: "QuestradeAccount")
    assert mine.reload.questrade_accounts.exists?(mine_link.id)
    assert mine_link.reload.account_provider.present?
    assert Account.exists?(mine_sure.id)
    assert Account.exists?(hers_sure.id)
  end

  private
    def link_brokerage_account(item, number)
      brokerage = item.questrade_accounts.create!(
        name: "TFSA (#{number})",
        questrade_account_id: number,
        account_type: "TFSA",
        currency: "CAD",
        current_balance: 100
      )
      sure = item.family.accounts.create!(
        name: "TFSA #{number}",
        balance: 0,
        currency: "CAD",
        accountable: Investment.new
      )
      brokerage.ensure_account_provider!(sure)
      brokerage
    end
end
