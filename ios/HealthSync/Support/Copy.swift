import Foundation

/// Every line of text on the redesigned screens, in one place (mirrors the copy deck in the design file).
enum Copy {
    enum Welcome {
        static let tagline = "Your Apple Health, meet your AI."
        static let subtitle = "Every workout, heartbeat and night of sleep from all your sources, ready for your AI."
        static let connectButton = "Connect to Apple Health"
        static let connectedButton = "Connected"
        /// Examples of what KROK can answer, scrolling slowly behind the tagline.
        static let questions = [
            "What are my fastest 5K and 10K efforts?",
            "Did my heart rate drift during yesterday’s long run?",
            "How has my training load changed over six weeks?",
            "Is my sleep and recovery better or worse than my usual?",
            "How long did I spend in each heart rate zone this week?",
            "What were my km splits on Sunday’s run?",
            "How much climbing was in my last long ride?",
            "How does my resting heart rate compare to last month?",
        ]
    }

    enum Account {
        static let headline = "Keep your data yours."
        static let body = "An account is needed to connect with AI. You can delete it and your data anytime."
        static let signIn = "Sign in with Apple"
        static let connected = "Apple Health connected"
        static let signingIn = "Signing in…"
    }

    enum Home {
        static let moreLabel = "More"
        static let estimating = "Estimating time left…"
        /// The time left as the top of a step (see `SyncEstimator.steps`): 30-second steps up to 3 minutes, then minutes, then ranges.
        static func timeLeft(seconds: Int) -> String {
            if seconds <= 60 { return "Less than a minute left" }
            if seconds <= 180 {
                let halves = (seconds + 29) / 30
                return halves % 2 == 0 ? "About \(halves / 2) min left" : "About \(halves / 2)½ min left"
            }
            let minutes = seconds / 60
            if seconds <= 600 { return "About \(minutes) min left" }
            let width = seconds <= 1_800 ? 5 : 10
            return "About \(minutes - width)–\(minutes) min left"
        }
        static let almostDone = "Almost done"
        static let overAnHour = "More than an hour left"
        static let keepOpen = "Keep the app open."
        static let upToDate = "Up to date"
        static let askYourAI = "ASK YOUR AI"
        static let copied = "COPIED"
        static let gettingReady = "Getting ready…"
        static let recentReady = "Your recent workouts are ready. You can already ask Claude or ChatGPT about them."
        static let noData = "No readable Health data found"
        static let noDataDetail = "Check Settings › Health › Data Access & Devices › KROK and turn on Workouts, Workout Routes and the other categories you want to share."
        static func connect(_ name: String) -> String { "Connect \(name)" }
        static let connected = "Connected"

        /// The four lines under the big number while the first sync runs, and the sentence under them.
        enum Line {
            static let indexing = "Indexing"
            static let everyDay = "Every day"
            static let everyHour = "Every hour"
            static let everyWorkout = "Every workout"
            static let reading = "Reading…"
            static let waiting = "Waiting"
            static let gettingReady = "Getting your workouts ready…"
            static let finishingUp = "Finishing up…"
            static func workouts(_ n: Int) -> String { n == 1 ? "1 workout" : "\(n.formatted()) workouts" }
            static func days(_ n: Int) -> String { n == 1 ? "1 day" : "\(n.formatted()) days" }
            static func hours(_ n: Int) -> String { n == 1 ? "1 hour" : "\(n.formatted()) hours" }
            static func progress(_ done: Int, of total: Int) -> String { "\(done.formatted()) / \(total.formatted())" }
            static func indexingEvery(_ noun: String, since: String) -> String { "Indexing every \(noun)\(since)…" }
            static func finishingEvery(_ noun: String, since: String) -> String { "Finishing every \(noun)\(since)" }
            static func since(_ year: Int) -> String { " since \(year)" }
            static let doneAccessibility = "done"
            static let runningAccessibility = "in progress"
            static let waitingAccessibility = "waiting"
        }
    }

    enum Menu {
        static let help = "Help & Support"
        static let privacy = "Privacy Policy"
        static let logOut = "Log out"
        static let deleteAll = "Delete All My Data"
        static let speedTest = "Run speed test (pauses sync)"
        static let signIn = "Sign in with Apple"
    }

    enum LogOut {
        static let title = "Log out of KROK?"
        static let message = "Your data and your Claude and ChatGPT connections stay as they are. Sign in with the same Apple Account to come back."
        static let confirm = "Log out"
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
        static let oauthCopyTitle = "Copy your KROK link"
        static func oauthOpenTitle(chatGPT: Bool) -> String { chatGPT ? "Open ChatGPT’s plugins" : "Open Claude’s connectors" }
        static func oauthOpenDetail(chatGPT: Bool) -> String {
            chatGPT ? "At the top right, tap “+”, then choose:" : "At the top right, tap “+ Add”, then choose:"
        }
        static func oauthChoice(chatGPT: Bool) -> String { chatGPT ? "Create custom MCP server" : "Add custom connector" }
        static let oauthFormTitle = "Fill in the form"
        static func oauthFormDetail(chatGPT: Bool) -> String {
            chatGPT ? "Keep “Server URL” selected under Connection. Then tap Create." : "Then tap Add."
        }
        static let oauthName = "Name"
        static let oauthAppName = "KROK"
        static func oauthLinkField(chatGPT: Bool) -> String { chatGPT ? "Server URL" : "Connection" }
        static let oauthYourLink = "Your KROK link"
        static let oauthAuthField = "Authentication"
        static let oauthAuthValue = "OAuth"
        static let oauthSignInTitle = "Sign in with Apple"
        static let oauthSignInDetail = "Use the same Apple Account, then tap Allow access."
        static let copy = "Copy"
        static func connectedTitle(_ name: String) -> String { "\(name) is connected" }
        static func connectedLead(_ name: String) -> String { "\(name) can read the Apple Health data you chose to share." }
        static let askYourAI = "ASK YOUR AI"
        static let exampleQuestions = [
            "How did my last long run go?",
            "Is my sleep better or worse than usual?",
            "What were my km splits on Sunday’s run?",
        ]
        static let genericError = "Something went wrong. Please try again."
    }

    enum Metric {
        static let heartRateLabel = "heart rate readings"
        static let heartRateCaption = "From every time you wore your watch."
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
        static let gpsCaption = "Mapping all your workout routes."
        static let climbedLabel = "metres climbed"
        static func climbedCaption(_ everests: String) -> String { "≈ \(everests)× Mount Everest" }
        static let climbedFallback = "Every metre uphill."
        static let heartbeatsLabel = "workout heartbeats"
        static let heartbeatsCaption = "That’s a lot of extra beats!"
        static let hrvLabel = "days of HRV tracked"
        static let hrvCaption = "Your recovery is just as important."
        static let cycledLabel = "km cycled"
        static func cycledCaption(_ tours: String) -> String { "≈ \(tours) Tours de France" }
        static let cycledFallback = "Every ride adds up."
        static let swumLabel = "km swum"
        static func swumCaption(_ lengths: String) -> String { "≈ \(lengths) Olympic pool lengths" }
        static let swumFallback = "Lap by lap."
        static let activeDaysLabel = "days with a workout"
        static let activeDaysCaption = "Showing up, day after day."
        static let typesLabel = "workout types"
        static let typesCaption = "Tracking everything that you’re into."
    }
}
