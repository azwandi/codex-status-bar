import Foundation
import Testing
@testable import CodexStatusBar

struct CodexUsageProviderTests {
    @Test
    func parsesLatestTokenCountEventFromJsonl() throws {
        let provider = CodexUsageProvider()

        let snapshot = try provider.parse(
            """
            {"timestamp":"2026-03-30T16:00:07.224Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":37.0,"window_minutes":300,"resets_at":1774895185},"secondary":{"used_percent":11.0,"window_minutes":10080,"resets_at":1775481985},"credits":null,"plan_type":"plus"}}}
            {"timestamp":"2026-03-30T16:00:16.825Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":17340,"cached_input_tokens":13440,"output_tokens":284,"reasoning_output_tokens":66,"total_tokens":17624}},"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":38.0,"window_minutes":300,"resets_at":1774895185},"secondary":{"used_percent":12.0,"window_minutes":10080,"resets_at":1775481985},"credits":null,"plan_type":"plus"}}}
            """
        )

        #expect(snapshot.primaryPercentUsed == 38)
        #expect(snapshot.primaryPercentRemaining == 62)
        #expect(snapshot.secondaryPercentUsed == 12)
        #expect(snapshot.secondaryPercentRemaining == 88)
        #expect(snapshot.accountLabel == "Codex plan: Plus")
        #expect(snapshot.metrics.count == 2)
        #expect(snapshot.metrics[0].title == "Primary window (5h)")
        #expect(snapshot.metrics[1].title == "Weekly window (7d)")
    }

    @Test
    func supportsSingleWindowSnapshots() throws {
        let provider = CodexUsageProvider()

        let snapshot = try provider.parse(
            """
            {"timestamp":"2026-03-30T16:00:07.224Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":49.6,"window_minutes":180,"resets_at":1774895185},"secondary":null,"credits":null,"plan_type":"pro"}}}
            """
        )

        #expect(snapshot.primaryPercentUsed == 50)
        #expect(snapshot.primaryPercentRemaining == 50)
        #expect(snapshot.secondaryPercentUsed == nil)
        #expect(snapshot.metrics.count == 1)
        #expect(snapshot.metrics[0].title == "Primary window (3h)")
        #expect(snapshot.accountLabel == "Codex plan: Pro")
    }

    @Test
    func throwsWhenNoTokenCountEventExists() {
        let provider = CodexUsageProvider()

        #expect(throws: CodexUsageError.self) {
            _ = try provider.parse(
                """
                {"timestamp":"2026-03-30T16:00:07.224Z","type":"event_msg","payload":{"type":"agent_message","message":"hello"}}
                """
            )
        }
    }
}
