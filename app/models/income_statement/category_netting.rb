# Arranges category nets for the Sankey. A refund is already inside the expense
# total. A refunding subcategory is folded into its parent, because that total
# already includes the child and a negative flow cannot be drawn. A category
# whose refunds exceed its spending is left off the diagram. The numeric
# spending totals still carry that negative amount, and it is not income.
#
# Shared by the category and account Sankeys, so both net a statement the same way.
class IncomeStatement::CategoryNetting
  def initialize(statement, period:)
    @statement, @period = statement, period
  end

  # One group per top-level category: its own net (`direct`) and its
  # subcategories' nets (`children`), positive meaning spending.
  #
  # Keep this hierarchy-aware netting separate from IncomeStatement#net_category_totals
  # while the original dashboard Sankey remains available for preview comparisons.
  def groups
    expense = @statement.expense_totals(period: @period).category_totals.index_by { |ct| self.class.key(ct.category) }
    income = @statement.income_totals(period: @period).category_totals.index_by { |ct| self.class.key(ct.category) }
    entries = (expense.keys | income.keys).sort.map do |key|
      category = (expense[key] || income[key]).category
      exp = (expense[key]&.total || 0).to_d
      inc = (income[key]&.total || 0).to_d
      {
        category: category,
        net: exp - inc,
        # Refunds already sit inside the expense total. A negative expense
        # with no income is a refund past the category's purchases, not income.
        surplus_refund: exp.negative? && inc <= 0
      }
    end
    children = entries.select { |entry| entry[:category].subcategory? }.group_by { |entry| entry[:category].parent_id }
    entries.reject { |entry| entry[:category].subcategory? }.map do |root|
      subs = children.fetch(root[:category].id, [])
      # Fold a refunding subcategory into its parent. The parent's total
      # already includes it; drawing the child as income would count it twice
      # and on the wrong side. The diagram cannot show a negative flow.
      refund_children, flow_children = subs.partition { |sub| sub[:surplus_refund] }
      direct = root[:net] - flow_children.sum { |sub| sub[:net] }
      {
        category: root[:category],
        direct: direct,
        direct_surplus_refund: direct.negative? && (root[:surplus_refund] || refund_children.any?),
        children: flow_children
      }
    end
  end

  class << self
    def key(category)
      return "uncategorized" if category.uncategorized?
      return "other_investments" if category.other_investments?
      category.id
    end

    # A surplus refund is omitted. Sankey links cannot be negative, and the
    # surplus is not income. Numeric spending totals still carry it.
    def side_amount(net, side, surplus_refund: false)
      return 0 if surplus_refund

      [ side == :expense ? net : -net, 0 ].max
    end

    def side_total(group, side)
      side_amount(group[:direct], side, surplus_refund: group[:direct_surplus_refund]) +
        group[:children].sum { |child| side_amount(child[:net], side, surplus_refund: child[:surplus_refund]) }
    end
  end
end
