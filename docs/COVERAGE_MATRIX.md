# What KROK reads from Apple Health

The machine-readable source is **`shared/coverage.json`**. It's bundled into the iOS app and imported by the server, so both sides always agree. Read-only: nothing is written to HealthKit.

Data is grouped in **categories**. `core` is always on; every other category is off until the user switches it on in the app (**Your data**), HealthKit permission for its types is requested only then, and switching it off deletes its data on the server (DATA_CONTRACT.md §7).

## Category: core (always on): Workouts, activity, sleep and recovery
### Workouts (everything Apple attaches)
| What | How the phone reads it |
|---|---|
| Summary: activity, start/end, duration, active energy, distance, average/max heart rate, source and device | `HKAnchoredObjectQuery` on `HKWorkoutType` (history + change capture + deletions) |
| Apple's statistics for every quantity recorded during the workout | `HKWorkout.allStatistics` |
| Metadata (weather, indoor/outdoor, elevation ascended, …); dew point and heat index are derived on the server from Apple's temperature and humidity | `HKWorkout.metadata` |
| Events (pause/resume/lap/segment) with Apple's details (swim stroke style, lap length), and sub-activities (multi-sport) | `workoutEvents`, `workoutActivities` |
| The plan the workout was run from, when it has one (from any app that schedules plans in Apple's Workout app) | `HKWorkout.workoutPlan` (WorkoutKit, iOS 17+) |
| **Raw streams**: 33 quantity types (heart rate, distance for every sport, steps, running speed/power/stride/ground contact/vertical oscillation, cycling power/speed/cadence, swimming strokes, effort score, SpO2, respiratory rate…). Streams of BasalEnergyBurned, ActiveEnergyBurned, AppleExerciseTime, PhysicalEffort, EnvironmentalAudioExposure, HeadphoneAudioExposure (6 further types) are **not** sent as streams; Apple's summary statistics for them are. | `HKSampleQuery` for samples associated with the workout; series samples expanded with `HKQuantitySeriesSampleQuery` |
| **GPS route** (latitude, longitude, altitude, speed, horizontal accuracy; about 1 m precision, every point) | `HKWorkoutRouteQuery` |

### All-day series
| What | How |
|---|---|
| Hourly heart rate (average, min, max), steps (sum), HRV SDNN and RMSSD (average) for the whole history | `HKStatisticsCollectionQuery`, hourly buckets, a year per batch |

### Daily context (66 metrics, one row per local day)
`restingHr`, `hrv`, `respiratoryRate`, `sleepingWristTempC`, `spo2Avg`, `spo2Min`, `walkingHrAvg`, `sleepBreathingDisturbances`, `sleep`, `steps`, `walkRunDistanceM`, `cyclingDistanceM`, `swimDistanceM`, `flightsClimbed`, `activeKcal`, `basalKcal`, `exerciseMin`, `standMin`, `daylightMin`, `physicalEffortAvg`, `rings`, `vo2max`, `walkingSpeedMps`, `walkingStepLengthM`, `walkingAsymmetryPct`, `walkingDoubleSupportPct`, `walkingSteadinessPct`, `stairAscentSpeedMps`, `stairDescentSpeedMps`, `sixMinuteWalkM`, `bodyMassKg`, `bodyFatPct`, `leanMassKg`, `bmi`, `heightM`, `waistM`, `hrAvg`, `hrMin`, `hrMax`, `hrvMin`, `hrvMax`, `hrvRmssd`, `respiratoryMin`, `respiratoryMax`, `spo2Max`, `uvExposure`, `moveMin`, `nikeFuel`, `wheelchairDistanceM`, `snowDistanceM`, `xcSkiDistanceM`, `paddleDistanceM`, `rowingDistanceM`, `skatingDistanceM`, `swimStrokes`, `pushCount`, `timesFallen`, `perfusionIndexPct`, `envAudioAvg`, `envAudioMax`, `headphoneAudioAvg`, `headphoneAudioMax`, `soundReductionAvg`, `bodyTempC`, `envAudioEvents`, `headphoneAudioEvents`.
Quantities use `HKStatisticsCollectionQuery` with day buckets (sum, average, min, max or latest); sleep, rings and categories use their own queries. Resting heart rate, HRV, respiratory rate, SpO₂, wrist temperature and VO₂ max read only Apple's own sources.

## Optional categories
| Category | Daily rows | Event / sample log |
|---|---|---|
| **nutrition**: Nutrition and alcohol | `dietaryKcal`, `proteinG`, `carbsG`, `fatG`, `sugarG`, `fiberG`, `sodiumG`, `waterL`, `caffeineG`, `alcoholBeverages` | 41 types: `DietaryEnergyConsumed`, `DietaryCarbohydrates`, `DietaryFiber`, `DietarySugar`, `DietaryFatTotal`, `DietaryFatMonounsaturated`, `DietaryFatPolyunsaturated`, `DietaryFatSaturated`, `DietaryCholesterol`, `DietaryProtein`, `DietarySodium`, `DietaryCaffeine`, `DietaryWater`, `DietaryVitaminA`, `DietaryVitaminB6`, `DietaryVitaminB12`, `DietaryVitaminC`, `DietaryVitaminD`, `DietaryVitaminE`, `DietaryVitaminK`, `DietaryBiotin`, `DietaryFolate`, `DietaryNiacin`, `DietaryPantothenicAcid`, `DietaryRiboflavin`, `DietaryThiamin`, `DietaryCalcium`, `DietaryChloride`, `DietaryChromium`, `DietaryCopper`, `DietaryIodine`, `DietaryIron`, `DietaryMagnesium`, `DietaryManganese`, `DietaryMolybdenum`, `DietaryPhosphorus`, `DietaryPotassium`, `DietarySelenium`, `DietaryZinc`, `NumberOfAlcoholicBeverages`, `BloodAlcoholContent` |
| **heart**: Heart alerts and lung function | – | 10 types: `AtrialFibrillationBurden`, `HighHeartRateEvent`, `LowHeartRateEvent`, `IrregularHeartRhythmEvent`, `LowCardioFitnessEvent`, `HypertensionEvent`, `ForcedExpiratoryVolume1`, `ForcedVitalCapacity`, `PeakExpiratoryFlowRate`, `InhalerUsage` |
| **devices**: Glucose, insulin and blood pressure | – | 4 types: `BloodGlucose`, `InsulinDelivery`, `BloodPressureSystolic`, `BloodPressureDiastolic` |
| **mind**: Mood and symptoms | `mindfulMin`, `stateOfMind` | 34 types: `AbdominalCramps`, `Acne`, `AppetiteChanges`, `Bloating`, `ChestTightnessOrPain`, `Chills`, `Constipation`, `Coughing`, `Diarrhea`, `Dizziness`, `DrySkin`, `Fainting`, `Fatigue`, `Fever`, `GeneralizedBodyAche`, `HairLoss`, `Headache`, `Heartburn`, `LossOfSmell`, `LossOfTaste`, `LowerBackPain`, `MemoryLapse`, `MoodChanges`, `Nausea`, `NightSweats`, `RapidPoundingOrFlutteringHeartbeat`, `RunnyNose`, `ShortnessOfBreath`, `SinusCongestion`, `SkippedHeartbeat`, `SleepChanges`, `SoreThroat`, `Vomiting`, `Wheezing` |
| **cycle**: Menstrual cycle | `basalBodyTempC`, `cycleMenstrualFlow`, `cycleIntermenstrualBleeding`, `cycleOvulationTestResult`, `cycleCervicalMucusQuality`, `cycleInfrequentMenstrualCycles`, `cycleIrregularMenstrualCycles`, `cyclePersistentIntermenstrualBleeding`, `cycleProlongedMenstrualPeriods` | – |
| **medications**: Medications | – | 1 types: `Medication` |
| **profile**: Profile (date of birth, sex, wheelchair use) | – | 1 types: `Profile` |

Notes: nutrition logs are per sample (with time and writing app) for all dietary types; the daily totals come from statistics queries so several apps are not double counted. Glucose readings are sent without per-reading ids (about 0.1 MB per year for a CGM). Medications are the list the user chooses to share (iOS 26 per-object authorization), not dose history. Symptoms exclude reproductive and urogenital ones.

## Not read (by decision)
- **clinical records and documents**: deferred to a later release (needs the health-records entitlement).
- **sexual activity, contraceptive, pregnancy and tests, lactation, progesterone test, bleeding in/after pregnancy, menopause**: removed: highest sensitivity, little coaching value.
- **GAD-7 / PHQ-9 questionnaires**: removed: clinical mental-health screening.
- **reproductive and urogenital symptoms (pelvic pain, breast pain, vaginal dryness, hot flashes, bladder incontinence)**: removed.
- **audiograms, vision prescriptions, handwashing, toothbrushing, skin conductance, blood type, skin type**: removed: no feature uses them.
- **ECG waveforms, heartbeat series, all-day raw background HR/energy/audio**: not small.
- Not readable by apps at all: Sleep Score, Training Load, sleep apnea notifications.

## Rules
- **Unavailable ≠ zero.** A metric with no data is omitted from the row; a workout without a route or heart rate simply has no such stream. Tools list which streams exist.
- **Read denials** are invisible to apps. If the user denies a type, it reads as empty.
- **Types missing on the running iOS version** are skipped, so newer types (for example HRV RMSSD) start syncing on newer phones without code changes.
- **Units** are set in `shared/coverage.json` and verified with `isCompatible` at runtime.
- **Selection rule:** a type is read only when a tool or feature uses it, and sensitive categories stay off until the user enables them.
