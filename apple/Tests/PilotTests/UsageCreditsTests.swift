import Foundation
import Testing
@testable import Pilot

@Suite("Credit usage bars")
struct UsageCreditsTests {
    @Test("Spending bars require a real allowance and remain finite")
    func denominators() {
        #expect(CreditInfo(balance: 37_703.18).fractionUsed == nil)
        #expect(CreditInfo(used: 25, limit: 100).fractionUsed == 0.25)
        #expect(CreditInfo(used: 0, limit: 100).fractionUsed == 0)
        #expect(CreditInfo(used: 120, limit: 100).fractionUsed == 1)
        #expect(CreditInfo(used: -5, limit: 100).fractionUsed == 0)
        #expect(CreditInfo(used: 25, limit: 0).fractionUsed == nil)
        #expect(CreditInfo(used: 25, limit: .infinity).fractionUsed == nil)
        #expect(CreditInfo(used: .nan, limit: 100).fractionUsed == nil)
        #expect(CreditInfo(utilization: .nan).fractionUsed == nil)
        #expect(CreditInfo(unlimited: true, utilization: 0.5).fractionUsed == nil)
        #expect(CreditInfo(utilization: 0.6).fractionUsed == 0.6)
    }

    @Test("Grok preserves prepaid credits and an on-demand budget together")
    func grokWalletAndBudget() throws {
        let usage = GrokUsageAdapter.parse([
            "prepaidBalance": ["val": 911],
            "onDemandUsed": ["val": 1_250],
            "onDemandCap": ["val": 5_000],
        ])
        let credit = try #require(usage.credits)
        #expect(credit.balance == 9.11)
        #expect(credit.used == 12.5)
        #expect(credit.limit == 50)
        #expect(credit.fractionUsed == 0.25)
    }

    @Test("Claude and Cursor expose extra spend independently of subscription quota")
    func separateSubscriptionAndCredits() {
        let claude = ClaudeUsageAdapter.parse([
            "seven_day": ["utilization": 97],
            "extra_usage": ["is_enabled": true, "used_credits": 1_250, "monthly_limit": 5_000],
        ])
        #expect(claude.windows.first?.utilization == 0.97)
        #expect(claude.credits?.fractionUsed == 0.25)
        let cursor = CursorUsageAdapter.parse(summary: [:], status: [
            "weeklyIncludedUsage": ["usedCents": 25, "budgetCents": 100],
            "monthlyUsage": ["usedCents": 750, "limitCents": 1_000],
        ])
        #expect(cursor.windows.first?.utilization == 0.25)
        #expect(cursor.credits?.fractionUsed == 0.75)
    }
}
