//
//  CategorizationSettingsView.swift
//  spending-tracker
//
//  The key, the status, and the two manual triggers.
//

import Foundation
import SwiftUI

/// Everything about the classifier in one place.
///
/// **One screen, and not on `DiagnosticsView`.** That screen answers "is capture still working"
/// for someone working out why an alert is missing, and it is written for a fault. This is
/// configuration for something the user opted into, plus a status line — and a key field belongs
/// where settings live, not where faults are expected to be found.
struct CategorizationSettingsView: View {

    let ledger: LedgerStore
    let categorizer: CategoryEngine

    @Environment(\.dismiss) private var dismiss

    @State private var draftKey = ""
    @State private var hasStoredKey = false
    @State private var message: String?
    @State private var isWorking = false
    @State private var counts = LedgerStore.CategorizationCounts()

    var body: some View {
        NavigationStack {
            Form {
                keySection
                privacySection
                statusSection
                actionSection
                errorSection
            }
            .navigationTitle("AI categorization")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { reload() }
        }
    }

    // MARK: - The key

    @ViewBuilder
    private var keySection: some View {
        Section {
            if hasStoredKey {
                // Never the key itself. There is nothing the user can do with it here that
                // warrants putting it back on a screen someone may be looking over.
                Label("A key is set", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Color.green)
                Button("Remove key", role: .destructive) { removeKey() }
            } else {
                SecureField("Paste your DeepSeek API key", text: $draftKey)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("API key")
                Button("Save key") { saveKey() }
                    .disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text("Key")
        } footer: {
            Text(hasStoredKey ? storedKeyFooter : missingKeyFooter)
        }
    }

    private var missingKeyFooter: String {
        "Without a key nothing is sent anywhere and every category is yours to set by hand. "
            + "The key goes in the keychain: not a file, not `UserDefaults`, and not the journal "
            + "— the Raw journal screen renders that file, and Diagnostics can export it."
    }

    private var storedKeyFooter: String {
        "Kept in the keychain, on this device only, so it is not restored onto a new phone from "
            + "a backup. It is never shown again, never written to the journal, and leaves the "
            + "phone only as the authorization header on a request to DeepSeek. Removing it is "
            + "the off switch."
    }

    /// Said plainly, and not folded into a footer somewhere.
    ///
    /// This is the one part of the feature that cannot be taken back once it has happened: a
    /// merchant descriptor is a small piece of a person's life — where they shop, who they pay —
    /// and it is being handed to a third party. The amount, the date, the card and the Venmo
    /// descriptors are all withheld, which is worth saying too, because "what exactly leaves my
    /// phone" is the question someone would actually have.
    private var privacySection: some View {
        Section {
            Text("Merchant names are sent to DeepSeek to be categorized. Amounts, dates and card "
                 + "digits stay on the phone. Payments, deposits and person-to-person rows are "
                 + "never sent at all — and never categorized.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            row("Classification", outcomeText)
            row("Filed by you", "\(counts.byPerson)")
            row("Filed by the model", "\(counts.byModel)")
            row("Waiting", "\(counts.waiting) charges, \(counts.merchantsWaiting) merchants")
            row("Merchant rules", "\(counts.userRules) yours, \(counts.modelRules) from the model")
        } header: {
            Text("Status")
        } footer: {
            Text(statusFooter)
        }
    }

    private var outcomeText: String {
        switch categorizer.outcome {
        case .idle:
            return hasStoredKey ? "Idle" : "No key — nothing is sent"
        case .running:
            return "Working…"
        case .answered(let count):
            return "Filed \(count) merchant\(count == 1 ? "" : "s") on the last pass"
        case .declined:
            return "The last pass could not read an answer out of the reply"
        case .failed(let reason):
            return "The last pass failed: \(reason)"
        case .blocked(let reason):
            return "Stopped: \(reason)"
        }
    }

    private var statusFooter: String {
        var parts = [
            "A pass runs when the app comes to the front, when you pull to refresh, and when the "
                + "network comes back while the app is open.",
            "A merchant that has been asked about unsuccessfully waits longer each time it "
                + "fails, up to a day. Nothing is ever given up on.",
        ]

        // Stated rather than left silent. A bounded run that says nothing reads as "everything
        // has been asked about", and the merchants it did not reach look like a stall.
        if counts.merchantsWaiting > CategoryEngine.merchantsPerRun {
            parts.append("One pass asks about at most \(CategoryEngine.merchantsPerRun) "
                         + "merchants, so the rest will be picked up over the next few times the "
                         + "app is opened.")
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Doing it now

    private var actionSection: some View {
        Section {
            Button {
                Task { await runPass(retrying: false) }
            } label: {
                Label("Categorize now", systemImage: "sparkles")
            }
            .disabled(isWorking || !hasStoredKey)

            Button {
                Task { await runPass(retrying: true) }
            } label: {
                Label("Try again now", systemImage: "arrow.clockwise")
            }
            .disabled(isWorking || !hasStoredKey)
        } footer: {
            Text("\"Categorize now\" asks about the merchants that are due. \"Try again now\" "
                 + "forgets every wait first — for when you have just fixed your network or your "
                 + "key and would rather not sit out a backoff.")
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let message {
            Section {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(Color.orange)
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - Actions

    private func reload() {
        hasStoredKey = CategoryKeychain.hasKey
        counts = ledger.categorizationCounts()
    }

    private func saveKey() {
        do {
            try CategoryKeychain.setAPIKey(draftKey)
            draftKey = ""
            message = nil
        } catch {
            message = error.localizedDescription
        }
        reload()
    }

    private func removeKey() {
        do {
            try CategoryKeychain.setAPIKey(nil)
            message = nil
        } catch {
            message = error.localizedDescription
        }
        reload()
    }

    private func runPass(retrying: Bool) async {
        isWorking = true
        if retrying {
            await categorizer.tryAgainNow()
        } else {
            await categorizer.run()
        }
        isWorking = false
        reload()
    }
}
