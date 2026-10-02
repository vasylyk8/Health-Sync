import Foundation

/// Every line of text on the redesigned screens, in one place (mirrors the copy deck in the design file).
enum Copy {
    enum Welcome {
        static let tagline = "Your Apple Health, meet your AI."
        static let connectButton = "Connect to Apple Health"
        static let chicagoCaption = "CHICAGO MARATHON"
        static let chicagoDate = "OCT 11, 2026"
        static let dataNote = "Your Apple Health data is copied securely to our servers in the EU so the assistants you connect can read it. Nothing is shared until you connect one."
    }

    enum Account {
        static let title = "Connect your KROK account"
        static let detail = "Sign in with Apple to use these workouts in Claude or ChatGPT. Your synced data stays in your KROK account."
        static let linked = "Apple Account linked"
    }

    enum Choices {
        static let title = "Your data"
        static let header = "Data your assistant can see"
        static let footer = "Apple Health asks for each group separately, and you can also change it in Apple Health. Switching a group off here deletes its data from KROK’s servers. Assistants describe your data and trends; they don’t give medical advice."
    }

    enum Home {
        static let moreLabel = "More"
        static let estimating = "Estimating time left…"
        static func minutesLeft(_ minutes: Int) -> String { "About \(minutes) min left" }
        static let almostDone = "Almost done"
        static let overAnHour = "More than an hour left"
        static let keepOpen = "Keep the app open while syncing."
        static let upToDate = "Up to date"
        static let gettingReady = "Getting ready…"
        static let recentReady = "Your recent workouts are ready. You can already ask Claude or ChatGPT about them."
        static let noData = "No readable Health data found"
        static let noDataDetail = "Check Settings › Health › Data Access & Devices › KROK and turn on Workouts, Workout Routes and the other categories you want to share."
        static func connect(_ name: String) -> String { "Connect \(name)" }
        static let connected = "Connected"
    }

    enum Menu {
        static let yourData = "Your data"
        static let help = "Help & Support"
        static let privacy = "Privacy Policy"
        static let deleteAll = "Delete All My Data"
        static let speedTest = "Run speed test (pauses sync)"
    }

    enum Delete {
        static let title = "Delete all your data from KROK?"
        static let message = "Connected assistants lose access immediately and your copy on our servers is erased. Apple Health itself is not changed."
        static let confirm = "Delete All My Data"
    }

    enum Sheet {
        static let close = "Close"
        static func connectTitle(_ name: String) -> String { "Connect \(name)" }
        static func consentTitle(_ name: String) -> String { "Share your workouts with \(name)?" }
        static func consentBody(_ name: String) -> String {
            "You’ll get a private link. With it, \(name) can read your workouts, heart rate, GPS routes, and daily and hourly summaries, plus any extra data groups you switch on, when you ask a question."
        }
        static func consentTerms(_ company: String) -> String {
            "\(company) processes that data under its own terms. You can disconnect at any time."
        }
        static let continueButton = "Continue"
        static let copyLink = "Copy link"
        static let copied = "Copied"
        static func openSite(_ site: String) -> String { "Open \(site)" }
        static func waiting(_ name: String) -> String { "Waiting for \(name) to connect…" }
        static func isSetUp(_ name: String) -> String { "\(name) is set up" }
        static func connectedBody(_ name: String) -> String {
            "Ask \(name) about your runs, rides, heart rate zones, pace and recovery. It reads your workout data only when you ask."
        }
        static func disconnect(_ name: String) -> String { "Disconnect \(name)" }
        static func disconnectTitle(_ name: String) -> String { "Disconnect \(name)?" }
        static let disconnectConfirm = "Disconnect"
        static func disconnectMessage(_ name: String) -> String {
            "\(name) will immediately lose access. You can also remove the KROK connector in \(name)’s settings."
        }
        static func authorizeTitle(_ name: String) -> String { "Authorize KROK in \(name)" }
        static let oauthIntro = "Add KROK in your assistant, then sign in with the Apple Account you linked here. You’ll choose what data it can read on the authorization page."
        static let oauthPending = "While directory approval is pending, use a custom connector with OAuth authentication."
        static let copyServerURL = "Copy KROK server URL"
        static func oauthHowTo(chatGPT: Bool) -> String {
            chatGPT
                ? "In ChatGPT, enable Developer mode, create KROK with this URL, and choose OAuth."
                : "In Claude, open Customize → Connectors → Add custom connector and paste this URL."
        }
        static let oauthWarning = "Don’t choose No authentication. KROK will open a sign-in and consent page."
        static let genericError = "Something went wrong. Please try again."
    }

    enum Metric {
        static let heartRateLabel = "heart rate readings"
        static let heartRateCaption = "From every workout, start to finish."
        static let workoutsLabel = "workouts"
        static let workoutsCaption = "From your first to your latest."
        static let stepsLabel = "steps"
        static func stepsCaption(_ marathons: String) -> String { "≈ \(marathons) marathons on foot" }
        static let stepsFallback = "Every step counts."
        static let walkRunLabel = "km walked and run"
        static func walkRunCaption(_ percent: String) -> String { "\(percent)% of the way around Earth" }
        static let walkRunFallback = "Every kilometre counts."
        static let sleepLabel = "hours of sleep tracked"
        static func sleepCaption(_ years: String) -> String { "≈ \(years) years asleep" }
        static let sleepFallback = "Night after night."
        static let caloriesLabel = "active calories burned"
        static func caloriesCaption(_ slices: String) -> String { "≈ \(slices) slices of pizza" }
        static let caloriesFallback = "Every bit of effort."
        static let trainingLabel = "hours of training"
        static func trainingCaption(_ days: String) -> String { "≈ \(days) days non-stop" }
        static let trainingFallback = "Hours well spent."
        static let historyLabel = "days of history"
        static func historyCaption(_ since: String) -> String { "Back to \(since)." }
        static let gpsLabel = "GPS points"
        static let gpsCaption = "All your routes, mapped."
        static let climbedLabel = "metres climbed"
        static func climbedCaption(_ everests: String) -> String { "≈ \(everests)× Mount Everest" }
        static let climbedFallback = "Every metre uphill."
        static let heartbeatsLabel = "workout heartbeats, estimated"
        static let heartbeatsCaption = "Counted from your heart rate."
        static let hrvLabel = "days of HRV tracked"
        static let hrvCaption = "Your recovery, tracked."
        static let cycledLabel = "km cycled"
        static func cycledCaption(_ tours: String) -> String { "≈ \(tours) Tours de France" }
        static let cycledFallback = "Every ride adds up."
        static let swumLabel = "km swum"
        static func swumCaption(_ lengths: String) -> String { "≈ \(lengths) pool lengths" }
        static let swumFallback = "Lap by lap."
        static let activeDaysLabel = "days with a workout"
        static let activeDaysCaption = "Showing up, day after day."
        static let typesLabel = "workout types"
        static let typesCaption = "From running to rowing."
    }
}
