# frozen_string_literal: true

require "application_system_test_case"

class QuestradeConnectionsTest < ApplicationSystemTestCase
  setup do
    sign_in users(:family_admin)
  end

  test "bank sync lists each questrade login and a form to add another" do
    visit settings_providers_path

    summary = find("details#questrade-connection > summary")
    summary.click

    questrade = find("details#questrade-connection")
    page.scroll_to(questrade, align: :center)

    within(questrade) do
      assert_text "My Questrade"
      assert_text "Stale Questrade"
      assert_text "Add another connection"
      assert_selector "form[action='#{questrade_items_path}']", visible: :all
    end

    within(questrade) do
      find("p", text: "My Questrade").click
      assert_field "Refresh Token"
      assert_button "Update Configuration"
      assert_button "Sync"
      assert_button "Disconnect"
      assert_link "Set up accounts"
    end
  end
end
