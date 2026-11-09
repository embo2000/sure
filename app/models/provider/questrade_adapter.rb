class Provider::QuestradeAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  # Register this adapter with the factory
  Provider::Factory.register("QuestradeAccount", self)

  # Define which account types this provider supports
  def self.supported_account_types
    # Questrade is a stock/ETF/options brokerage, so it only links to
    # Investment accounts (not Crypto).
    %w[Investment]
  end

  # One config per Questrade login, so adding an account targets that login.
  # A family with no connection, or exactly one, still sees the single
  # "Questrade" choice. The single connection's path is pinned to its id.
  def self.connection_configs(family:)
    return [] unless family.can_connect_questrade?

    items = family.questrade_items.credentialed.ordered.to_a
    return [ connection_config_for(nil) ] if items.empty?
    return [ connection_config_for(items.first, single: true) ] if items.one?

    items.map { |item| connection_config_for(item) }
  end

  def provider_name
    "questrade"
  end

  # Build a Questrade provider instance with family-specific credentials.
  # @param family [Family] The family to get credentials for (required)
  # @param questrade_item_id [String, nil] Required when the family has more
  #   than one credentialed connection.
  # @return [Provider::Questrade, nil] Returns nil if credentials are not configured
  def self.build_provider(family: nil, questrade_item_id: nil)
    return nil unless family.present?

    questrade_item = QuestradeItem.resolve_for(family: family, questrade_item_id: questrade_item_id)
    return nil unless questrade_item&.credentials_configured?

    questrade_item.questrade_provider
  end

  def self.connection_config_for(questrade_item, single: false)
    path_params = ->(extra = {}) {
      questrade_item.present? ? extra.merge(questrade_item_id: questrade_item.id) : extra
    }
    named = questrade_item.present? && !single

    {
      key: named ? "questrade_#{questrade_item.id}" : "questrade",
      name: named ? I18n.t("questrade_items.provider_connection.name", name: questrade_item.name) : I18n.t("questrade_items.provider_connection.default_name"),
      description: named ? I18n.t("questrade_items.provider_connection.description", name: questrade_item.name) : I18n.t("questrade_items.provider_connection.default_description"),
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.select_accounts_questrade_items_path(
          path_params.call(accountable_type: accountable_type, return_to: return_to)
        )
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_questrade_items_path(
          path_params.call(account_id: account_id)
        )
      }
    }
  end
  private_class_method :connection_config_for

  def sync_path
    Rails.application.routes.url_helpers.sync_questrade_item_path(item)
  end

  def item
    provider_account.questrade_item
  end

  def can_delete_holdings?
    false
  end

  def institution_domain
    metadata = provider_account.institution_metadata
    return nil unless metadata.present?

    domain = metadata["domain"]
    url = metadata["url"]

    # Derive domain from URL if missing
    if domain.blank? && url.present?
      begin
        domain = URI.parse(url).host&.gsub(/^www\./, "")
      rescue URI::InvalidURIError
        Rails.logger.warn("Invalid institution URL for Questrade account #{provider_account.id}: #{url}")
      end
    end

    domain
  end

  def institution_name
    metadata = provider_account.institution_metadata
    return nil unless metadata.present?

    metadata["name"] || item&.institution_name
  end

  def institution_url
    metadata = provider_account.institution_metadata
    return nil unless metadata.present?

    metadata["url"] || item&.institution_url
  end

  def institution_color
    item&.institution_color
  end
end
