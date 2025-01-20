// Copyright (C) 2024 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI
@preconcurrency import SushitrainCore
import BackgroundTasks

#if os(iOS)
	@MainActor class BackgroundManager: ObservableObject {
		private static let longBackgroundSyncID = "nl.t-shaped.sushitrain.background-sync"
		private static let shortBackgroundSyncID = "nl.t-shaped.sushitrain.short-background-sync"
		private static let watchdogNotificationID = "nl.t-shaped.sushitrain.watchdog-notification"

		// Time before the end of allotted background time to start ending the task to prevent forceful expiration by the OS
		private static let backgroundTimeReserve: TimeInterval = 5.6

		private var currentBackgroundTask: BGTask? = nil
		private var expireTimer: Timer? = nil
		private var isEndingBackgroundTask = false
		private var currentRun: BackgroundSyncRun? = nil
		fileprivate unowned var appState: AppState

		// Using this to store background information instead of AppStorage because it comes with observers that seem to
		// trigger SwiftUI hangs when the app comes back to the foreground.
		var backgroundSyncRuns: [BackgroundSyncRun] {
			set(newValue) {
				let encoded = try! JSONEncoder().encode(newValue)
				UserDefaults.standard.setValue(encoded, forKey: "backgroundSyncRuns")
			}
			get {
				if let encoded = UserDefaults.standard.data(forKey: "backgroundSyncRuns") {
					if let runs = try? JSONDecoder().decode([BackgroundSyncRun].self, from: encoded)
					{
						return runs
					}
				}
				return []
			}
		}

		var lastBackgroundSyncRun: BackgroundSyncRun? {
			set(newValue) {
				let encoded = try! JSONEncoder().encode(newValue)
				UserDefaults.standard.setValue(encoded, forKey: "lastBackgroundSyncRun")
			}
			get {
				if let encoded = UserDefaults.standard.data(forKey: "lastBackgroundSyncRun") {
					return try! JSONDecoder().decode(BackgroundSyncRun.self, from: encoded)
				}
				return nil
			}
		}

		required init(appState: AppState) {
			self.appState = appState

			// Schedule background synchronization task
			BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.longBackgroundSyncID, using: nil) {
				task in
				Task { await self.handleBackgroundSync(task: task) }
			}
			BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.shortBackgroundSyncID, using: nil) {
				task in
				Task { await self.handleBackgroundSync(task: task) }
			}
			updateBackgroundRunHistory(appending: nil)
			_ = self.scheduleBackgroundSync()

			Task.detached {
				await self.rescheduleWatchdogNotification()
			}
		}

		private func handleBackgroundSync(task: BGTask) async {
			let start = Date.now
			self.currentBackgroundTask = task
			Log.info("Start background task at \(start) \(task.identifier)")
			DispatchQueue.main.async {
				_ = self.scheduleBackgroundSync()
			}
			Log.info("Rescheduling watchdog")
			await self.rescheduleWatchdogNotification()

			// Start photo synchronization if the user has enabled it
			var photoSyncTask: Task<(), Error>? = nil
			if self.appState.photoSync.enableBackgroundCopy {
				Log.info("Start photo sync task")
				self.appState.photoSync.synchronize(
					self.appState, fullExport: false, isInBackground: true)
				photoSyncTask = self.appState.photoSync.syncTask
			}

			// Start background sync on long and short sync task
			if appState.longBackgroundSyncEnabled || appState.shortBackgroundSyncEnabled {
				Log.info(
					"Start background sync, time remaining = \(UIApplication.shared.backgroundTimeRemaining)"
				)
				self.appState.suspend(false)
				currentRun = BackgroundSyncRun(started: start, ended: nil)
				self.lastBackgroundSyncRun = currentRun

				expireTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { t in
					DispatchQueue.main.async {
						let remaining = UIApplication.shared.backgroundTimeRemaining
						Log.info("Check background time remaining: \(remaining)")
						// iOS seems to start expiring us at 5 seconds before the end
						if remaining <= Self.backgroundTimeReserve {
							Log.info("End of our background stint is nearing")
							self.endBackgroundTask()
						}
					}
				}

				// Run to expiration
				task.expirationHandler = {
					Log.warn(
						"Background task expired (this should not happen because our timer should have expired the task first; perhaps iOS changed its mind?) Remaining = \(UIApplication.shared.backgroundTimeRemaining)"
					)
					self.endBackgroundTask()
				}
			}
			else {
				// We're just doing some photo syncing this time
				if task.identifier == Self.longBackgroundSyncID {
					// When background task expires, end photo sync
					task.expirationHandler = {
						Log.warn(
							"Photo sync task expiry with \(UIApplication.shared.backgroundTimeRemaining) remaining."
						)
						self.appState.photoSync.cancel()
					}

					expireTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { t in
						DispatchQueue.main.async {
							let remaining = UIApplication.shared.backgroundTimeRemaining
							Log.info(
								"Check background time remaining (photo sync): \(remaining)"
							)

							// iOS seems to start expiring us at 5 seconds before the end
							if remaining <= Self.backgroundTimeReserve {
								Log.info(
									"End of our background stint is nearing (photo sync)"
								)
								self.appState.photoSync.cancel()
							}
						}
					}

					// Wait for photo sync to finish
					try? await photoSyncTask?.value
					Log.info("Photo sync ended gracefully")
					task.setTaskCompleted(success: true)
					self.expireTimer?.invalidate()
					self.expireTimer = nil
					self.currentBackgroundTask = nil
					Log.info("Photo sync task ended gracefully")
				}
				else {
					// Do not do any photo sync on short background refresh
					Log.info("Photo sync not started on short background refresh")
					task.setTaskCompleted(success: true)
					self.currentBackgroundTask = nil
				}
			}
		}

		private func endBackgroundTask() {
			Log.info(
				"endBackgroundTask: expireTimer=\(expireTimer != nil), run = \(currentRun != nil) task = \(currentBackgroundTask != nil), isEndingBackgroundTask = \(isEndingBackgroundTask)"
			)
			expireTimer?.invalidate()
			expireTimer = nil

			if var run = currentRun, let task = currentBackgroundTask, !isEndingBackgroundTask {
				self.isEndingBackgroundTask = true
				run.ended = Date.now

				Log.info("Background sync stopped at \(run.ended!.debugDescription)")
				self.appState.photoSync.cancel()

				Log.info("Suspending peers")
				self.appState.suspend(true)

				Log.info("Setting task completed")
				task.setTaskCompleted(success: true)

				Log.info("Doing background task bookkeeping")
				self.lastBackgroundSyncRun = run
				self.updateBackgroundRunHistory(appending: run)

				Log.info("Notify user of background sync completion")
				self.notifyUserOfBackgroundSyncCompletion(start: run.started, end: run.ended!)

				Log.info("Final cleanup")
				self.isEndingBackgroundTask = false
				self.currentBackgroundTask = nil
				self.currentRun = nil
			}
		}

		private func notifyUserOfBackgroundSyncCompletion(start: Date, end: Date) {
			if self.appState.notifyWhenBackgroundSyncCompletes {
				let duration = Int(end.timeIntervalSince(start))
				let content = UNMutableNotificationContent()
				content.title = String(localized: "Background synchronization completed")
				content.body = String(
					localized: "Background synchronization ran for \(duration) seconds")
				content.interruptionLevel = .passive
				content.sound = .none
				let uuidString = UUID().uuidString
				let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 30, repeats: false)
				let request = UNNotificationRequest(
					identifier: uuidString, content: content, trigger: trigger)
				let notificationCenter = UNUserNotificationCenter.current()
				notificationCenter.add(request)
			}
		}

		func scheduleBackgroundSync() -> Bool {
			var success = true

			if appState.longBackgroundSyncEnabled {
				let longRequest = BGProcessingTaskRequest(identifier: Self.longBackgroundSyncID)

				// No earlier than within 15 minutes
				longRequest.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
				longRequest.requiresExternalPower = true
				longRequest.requiresNetworkConnectivity = true
				Log.info(
					"Scheduling next long background sync for (no later than) \(longRequest.earliestBeginDate!)"
				)

				do {
					try BGTaskScheduler.shared.submit(longRequest)
				}
				catch {
					Log.warn("Could not schedule background sync: \(error)")
					success = false
				}
			}

			if appState.shortBackgroundSyncEnabled {
				let shortRequest = BGAppRefreshTaskRequest(identifier: Self.shortBackgroundSyncID)
				// No earlier than within 15 minutes
				shortRequest.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
				Log.info(
					"Scheduling next short background sync for (no later than) \(shortRequest.earliestBeginDate!))"
				)
				do {
					try BGTaskScheduler.shared.submit(shortRequest)
				}
				catch {
					Log.warn("Could not schedule short background sync: \(error)")
					success = false
				}
			}

			return success
		}

		@MainActor
		func rescheduleWatchdogNotification() async {
			Log.info("Re-schedule watchdog notification")
			let notificationCenter = UNUserNotificationCenter.current()
			UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [
				Self.watchdogNotificationID
			])

			let appState = self.appState
			var interval: TimeInterval = TimeInterval(appState.watchdogIntervalHours * 60 * 60)  // seconds
			if interval < 60.0 {
				interval = 60.0 * 60.0  // one hour minimum
			}

			if appState.watchdogNotificationEnabled {
				notificationCenter.getNotificationSettings { @MainActor settings in
					let status = settings.authorizationStatus
					if status == .authorized || status == .provisional {
						let content = UNMutableNotificationContent()
						content.title = String(localized: "Synchronisation did not run")
						content.body = String(
							localized:
								"Background synchronization last ran more than \(Int(interval / 3600)) hours ago. Open the app to synchronize."
						)
						content.interruptionLevel = .passive
						content.sound = .none
						content.badge = 1
						let trigger = UNTimeIntervalNotificationTrigger(
							timeInterval: interval, repeats: true)
						let request = UNNotificationRequest(
							identifier: Self.watchdogNotificationID, content: content,
							trigger: trigger)
						notificationCenter.add(request) { err in
							if let err = err {
								Log.warn(
									"Could not add watchdog notification: \(err.localizedDescription)"
								)
							}
							else {
								Log.info("Watchdog notification added")
							}
						}
					}
					else {
						Log.warn("Watchdog not enabled or denied, not reinstalling")
					}
				}
			}
		}

		private func updateBackgroundRunHistory(appending run: BackgroundSyncRun?) {
			var runs = self.backgroundSyncRuns

			// Remove old runs (older than 24h)
			let now = Date.now
			runs.removeAll(where: { r in
				return now.timeIntervalSince(r.started) > (24 * 60 * 60)
			})

			// Append our run
			if let run = run {
				runs.append(run)
			}
			self.backgroundSyncRuns = runs
		}
	}
#endif
