# Build Live Activities

Walkie's **Builds** toolbar button lists GitHub Actions runs from projects open in Cockpit. Choose **Follow Build** on a queued or running workflow to show its repository, branch, workflow, elapsed time, and result on the Lock Screen and Dynamic Island. Tapping the activity opens Builds; **View on GitHub** opens the specific run attempt. Following another run replaces the current activity. This does not start or cancel GitHub workflows.

## Data flow

1. Cockpit's existing repository scheduler advertises recent runs over authenticated peer sync. Worktrees of one repository are deduplicated. Older workspace snapshots still decode without this optional field.
2. Walkie starts an ActivityKit activity and obtains its activity-specific APNs token. A random 256-bit capability authorizes this one monitor. Walkie registers the token with the rendezvous worker, then sends the capability to its paired Mac over authenticated sync. Capabilities are stored in each app's device-only Keychain.
3. Cockpit polls the exact repository/run/attempt every 30 seconds using its existing `gh` authentication. It sends state directly while Walkie is connected, and posts state to the relay after push registration succeeds. GitHub credentials stay on the Mac.
4. `BuildActivityRoom` persists the latest state, coalesces pending updates, and sends signed APNs `liveactivity` pushes using Durable Object alarms. Transient failures retry with bounded backoff; invalid tokens stop delivery. Token rotation preserves the original expiry. Older updates and transitions out of a completed result are ignored.
5. Completion freezes the timer and ends the activity, retaining the result for 15 minutes. Stop Following revokes monitoring and immediately removes the local activity. Monitors expire after eight hours; the relay deletes their stored data at expiry.

Cockpit must remain running, awake, and online. Walkie can be backgrounded or terminated after registration because APNs updates the activity. If the Mac sleeps, loses GitHub access, or cannot reach the relay, the activity shows **Updates delayed** after two minutes. An elapsed timer is elapsed wall time, not proof that a build is still running. Updates are subject to Apple's delivery and activity budgets.

This version follows one attempt at a time. It does not automatically follow reruns or start activities remotely. Repository and branch names appear on the Lock Screen after the user chooses Follow Build. The relay sees the run identity, timing/status, and APNs token; no source code, logs, transcript, or GitHub credential is uploaded.

## Enable production push delivery

The implementation is complete in the repository, but a provisioned device and configured APNs provider are required for real delivery.

1. Enable **Push Notifications** for the Apple Developer App ID `app.blau.copilot` and refresh the app's provisioning profiles. Keep the widget extension's bundle ID `app.blau.copilot.widgets`. The Live Activity topic is fixed to `app.blau.copilot.push-type.liveactivity` in the worker.
2. Create or reuse an APNs signing key authorized for this app and environment. Store its key ID, team ID, and `.p8` private key as rendezvous Worker secrets. Do not commit a key or paste it into chat. From `workers/rendezvous`:

   ```sh
   bunx wrangler secret put APNS_KEY_ID
   bunx wrangler secret put APNS_TEAM_ID
   bunx wrangler secret put APNS_PRIVATE_KEY < /absolute/path/to/AuthKey.p8
   ```

3. Deploy the rendezvous worker with the new `BUILD_ACTIVITIES` Durable Object binding and `v3` SQLite migration: `bun run deploy` from `workers/rendezvous`. The required secret names are declared in `wrangler.jsonc`; the endpoint is `https://rendezvous.blau.app/live-activities/`.
4. Build and install Cockpit and Walkie. Debug uses the development APNs entitlement and sandbox endpoint. Release/Chromium uses the production entitlement and production endpoint. If an export process changes the signing environment, keep `APS_ENVIRONMENT` and `BUILD_PUSH_ENVIRONMENT` aligned. Regenerate the Xcode project after changing settings: `apple/bin/install-xcodegen.sh generate --spec apple/project.yml`.

The relay accepts only POST JSON at `/register`, `/update`, and `/end` under `/live-activities/`, with the per-monitor capability in the Authorization header. Requests have a 4 KB body limit, IP/capability rate limits, and a fixed APNs topic. Requests without configured provider secrets return 503; Walkie keeps local updates working and explains that background delivery is unavailable.

## Verification

Automated tests cover GitHub response parsing, attempt identity, timestamp encoding, legacy snapshot decoding, relay authorization/validation, token rotation, expiry, APNs retry/coalescing, terminal-state ordering, and ES256 signature verification. UI attachments render the actual Lock Screen card in light/dark running, delayed, success, and failure states, plus the Builds picker.

```sh
bun run --cwd workers/rendezvous check
bun run --cwd workers/rendezvous lint
bun run --cwd workers/rendezvous test
```

Apple test suites: `SharedTests/BuildWorkflowRunTests`, `SharedTests/BuildPresentationTests`, `SharedTests/SyncMessagesTests`, `PilotTests/RepositoryPollingSchedulerTests`, and `PilotTests/WorkspaceActionWatcherTests`.

Before shipping, use a signed physical iPhone and the deployed relay: pair with Cockpit, follow a running build, confirm the background-ready message, lock the phone, and let the workflow finish. Confirm the final result without reopening Walkie. Repeat with failure, cancellation, disconnect/reconnect, Mac sleep, Stop Following, and a rerun. Verify that sleep produces the delayed label and that the activity remains tied to its original attempt. Simulator rendering and mocked APNs tests do not establish real push delivery.

References: [ActivityKit push updates](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications), [APNs provider connections](https://developer.apple.com/documentation/usernotifications/establishing-a-connection-to-apns), and [Durable Object alarms](https://developers.cloudflare.com/durable-objects/api/alarms/).
