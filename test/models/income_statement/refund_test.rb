require "test_helper"

class IncomeStatement::RefundTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Checking", currency: "USD", balance: 0, accountable: Depository.new)
    @shopping = @family.categories.create!(name: "Shopping", color: "#3b82f6")
    @electronics = @family.categories.create!(name: "Electronics", color: "#3b82f6", parent: @shopping)
    @income = @family.categories.create!(name: "Income", color: "#22c55e")
    @bonus = @family.categories.create!(name: "Bonus", color: "#22c55e", parent: @income)
    @salary = @family.categories.create!(name: "Salary", color: "#16a34a", classification_unused: "income")
    @statement = IncomeStatement.new(@family)
    @period = Period.current_month
  end

  test "an expense-category inflow reduces that category, its parent, and total spending" do
    create_transaction(account: @account, amount: 100, category: @shopping)
    create_transaction(account: @account, amount: 40, category: @electronics)
    create_transaction(account: @account, amount: -15, category: @electronics)

    expenses = @statement.expense_totals(period: @period)
    income = @statement.income_totals(period: @period)

    assert_equal 125, expenses.total
    assert_equal 0, income.total
    assert_equal 125, category_total(expenses, @shopping)
    assert_equal 25, category_total(expenses, @electronics)
    assert_equal 0, category_total(income, @shopping)
  end

  test "a refund larger than the category's spending is negative spending, not income" do
    create_transaction(account: @account, amount: 100, category: @shopping)
    create_transaction(account: @account, amount: BigDecimal("-1384.26"), category: @shopping)

    expenses = @statement.expense_totals(period: @period)
    totals = @statement.totals(date_range: @period.date_range)

    assert_equal BigDecimal("-1284.26"), expenses.total
    assert_equal BigDecimal("-1284.26"), category_total(expenses, @shopping)
    assert_equal Money.new(0, "USD"), totals.income_money
    assert_equal Money.new(BigDecimal("-1284.26"), "USD"), totals.expense_money

    net = @statement.net_category_totals(period: @period)
    assert_equal BigDecimal("-1284.26"), net.total_net_expense
    assert_equal 0, net.total_net_income
  end

  test "income-category inflows, including a subcategory and a legacy classification, stay income" do
    create_transaction(account: @account, amount: -1000, category: @income)
    create_transaction(account: @account, amount: -75, category: @bonus)
    create_transaction(account: @account, amount: -40, category: @salary)
    create_transaction(account: @account, amount: -10)

    income = @statement.income_totals(period: @period)
    expenses = @statement.expense_totals(period: @period)

    assert_equal 1125, income.total
    assert_equal 0, expenses.total
    assert_equal 1075, category_total(income, @income)
    assert_equal 75, category_total(income, @bonus)
    assert_equal 40, category_total(income, @salary)
  end

  test "the daily spending series drops on the day of a refund" do
    create_transaction(account: @account, amount: 80, category: @shopping, date: Date.current)
    create_transaction(account: @account, amount: -30, category: @shopping, date: Date.current)

    day = @statement.daily_expense_series(period: @period).find { |row| row.date == Date.current }

    assert_equal 50, day.total
  end

  test "transfer kinds are unchanged" do
    create_transaction(account: @account, amount: 12, category: @shopping)
    create_transaction(account: @account, amount: -500, kind: "funds_movement")
    create_transaction(account: @account, amount: -90, kind: "cc_payment")
    create_transaction(account: @account, amount: -20, kind: "loan_payment")
    create_transaction(account: @account, amount: 35, kind: "investment_contribution")

    totals = @statement.totals(date_range: @period.date_range)

    assert_equal Money.new(67, "USD"), totals.expense_money
    assert_equal Money.new(0, "USD"), totals.income_money
  end

  test "a family that does not count investing as spending still excludes contributions" do
    @family.update!(investment_contributions_as_spending: false)
    create_transaction(account: @account, amount: 35, kind: "investment_contribution")
    create_transaction(account: @account, amount: -8, category: @shopping)

    totals = IncomeStatement.new(@family).totals(date_range: @period.date_range)

    assert_equal Money.new(-8, "USD"), totals.expense_money
    assert_equal Money.new(0, "USD"), totals.income_money
    assert_equal Money.new(35, "USD"), totals.invested_money
  end

  test "budgets net the refund against the category and keep income inflows in actual income" do
    create_transaction(account: @account, amount: 200, category: @shopping)
    create_transaction(account: @account, amount: -50, category: @shopping)
    create_transaction(account: @account, amount: -1000, category: @income)
    create_transaction(account: @account, amount: -25)
    create_transaction(account: @account, amount: -80, kind: "cc_payment")

    budget = Budget.find_or_bootstrap(@family, start_date: Date.current.beginning_of_month)
    budget.sync_budget_categories
    shopping = budget.budget_categories.find_by!(category: @shopping)

    assert_equal 150, budget.budget_category_actual_spending(shopping)
    assert_equal 150, budget.actual_spending
    assert_equal 1025, budget.actual_income
  end

  test "the cash flow report uses the same net spending and income" do
    create_transaction(account: @account, amount: 200, category: @shopping)
    create_transaction(account: @account, amount: -50, category: @shopping)
    create_transaction(account: @account, amount: -1000, category: @income)

    report = IncomeStatement::CashFlow.new(
      @statement,
      month: Date.current.beginning_of_month,
      as_of: Date.current
    ).as_json

    assert_equal "150.0", report[:spending]
    assert_equal "1000.0", report[:income]
    assert_equal "150.0", report.dig(:spending_comparison, :current_total)
  end

  private
    def category_total(period_total, category)
      period_total.category_totals.find { |row| row.category.id == category.id }.total
    end
end
