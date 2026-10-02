# Architecture notes

These notes cover how data moves through the app and why it is built that way. The README covers setup.

## Data model

```
UserProfile          1 row. Body data, goal, activity, plus a snapshot of the
                     inputs used when targets were last calculated.
NutritionTarget      1 row. Five NutrientRange values, each holding min, max and
                     minManuallyModified / maxManuallyModified.
FoodEntry            One per logged food. Has a consumedAt timestamp and no meal type.
  └─ IngredientItem  Zero or more (cascade delete). Has an explicit `position`,
                     because SwiftData does not keep to-many order.
BarcodeProductCache  Keyed by barcode. `isUserEntered` rows rank first and
                     never expire.
CorrectionRecord     Prediction JSON and confirmed-draft JSON (opt-in, on-device only).
AppSettings          1 row. Feature toggles and the assistant opt-in. Never
                     holds secrets.
```

Nutrition is always stored **per serving size**. Totals are worked out on demand:

```
ingredient.total = nutritionPerServing × quantity / servingSize
entry.total      = (composite ? Σ ingredient.total : nutritionPerServing)
                   × quantity / servingSize
```

## Paths into the database

```
Manual     ─┐
Photo AI   ─┤
Barcode    ─┼─► FoodEntryDraft ─► Add Meal review ─► FoodEntry (SwiftData)
Assistant  ─┘        (assistant: confirmation card instead of Add Meal)
```

Two places in the code write food entries:

- `AddMealView.save()`
- `AssistantToolExecutor.commit(_:)`. The executor only runs it after you tap confirm on a proposal. Its `execute(_:)` method can only produce proposals, never writes.

## Photo pipeline

```
UIImage
  → ImagePreparer.prepare      orientation fix, resize to 640 px long edge, BGRA buffer + JPEG
  → Model A (Core ML via Vision, .scaleFill)
        class_confidence[C], class_area[C], labels in model metadata
        (or a Vision object detector, if one is swapped in)
      ↳ on failure or empty result: optional RemoteVisionService
  → Model B (Core ML via Vision)
        mass, calories, protein, carbs, fat
      ↳ on failure: split an assumed total mass by detected area
  → NutritionRepository.resolve
        local verified → MyFCD / generic table (by canonical ID, then by name via ontology)
        → leftover share of Model B's plate estimate for anything unmatched
  → PhotoAnalysisResult → makeDraft() → Add Meal
```

Vision runs both models because they take a fixed square input and Vision rescales to fit. Training uses the same square stretch.

## Local day and midnight

Three components handle the day boundary:

- `LocalDay` uses half-open `[start, end)` intervals from `Calendar.dateInterval(of: .day)`. That handles 23- and 25-hour DST days correctly.
- `DayChangeObserver` republishes `currentDayStart` when any of these fire:
  - `NSCalendarDayChanged`
  - `NSSystemTimeZoneDidChange`
  - `significantTimeChangeNotification`
  - returning to the foreground
- The Dashboard filters an `@Query` of entries by that day, so the totals reset with no data mutation.

## Trends

`TrendAggregator` buckets `FoodEntry` rows by day, week or month on the fly.

- **Daily** buckets plot totals.
- **Weekly and monthly** buckets plot the average per elapsed day, so they stay comparable with a daily target band.
- **Empty buckets** are "no data", not zero.
- **Sparse buckets** (under half the days logged) are drawn faded.

The Dashboard rings and the trend tallies use the same `NutrientRange.state(consumed:)` function.

## Assistant loop

```
send() → service.send(turns, freshly built context JSON, tools)
  ├─ text → transcript
  └─ tool calls, in order:
       read tool  → execute → tool_result
       write tool → PendingAssistantWrite → confirmation card → PAUSE
                    (any later calls get a "deferred" tool_result)
confirm → commit → tool_result → resume loop
decline → "declined" tool_result → resume loop
```

The loop is capped at 5 round trips per user message.

The context sent with each request holds:

- the profile summary
- the five ranges, with consumed, remaining and still-needed amounts
- today's entries
- a 14-day tally

It is rebuilt for every request and never stored with the provider.
