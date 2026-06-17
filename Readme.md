## Product Overview

The proposed system aims to support an automatic decision on whether to start a parking charge based on confidence.

Instead of relying solely on GPS position, the system follows a confidence-based approach: automatic charging should only start when the system is sufficiently confident the vehicle is parked in a public area where payment applies.

## System Architecture and Implementation

Our architecture begins with an Android app written in Kotlin. The app collects real phone sensor data during a fixed 10-second observation window. During that interval, signals such as GPS accuracy, GPS signal loss, altitude variation, atmospheric pressure, and nearby visible Wi‑Fi networks are gathered.

After collection, the raw data is transformed locally within the app into aggregated features such as `gps_accuracy_mean`, `gps_lost_ratio`, `pressure_delta`, `altitude_delta`, `vertical_change_abs`, and `stationary_ratio`. This step is important because the app does not send sensitive raw data like Wi‑Fi SSIDs, Bluetooth identifiers, or continuous location. Instead, it only sends statistical values useful for the model, following a data minimization and privacy-by-design approach.

The app then sends these features as JSON to an API built with FastAPI. The API receives the values, arranges them in the same order used during model training, and passes them to our Machine Learning model.

The implemented model is a supervised `RandomForestClassifier` trained to distinguish three vertical contexts: `street_level`, `underground`, and `above`. Internally, the model computes the probability for each class. For the main decision, we sum the probabilities of `underground` and `above` because in both cases the vehicle is not on a normal street-level public road. This yields a value called `non_street_confidence` between 0 and 1.

Finally, the API returns two values to the app: `non_street_confidence`, representing the probability the vehicle is not at normal street level, and `classification`, provided for debugging, indicating whether the model considers the vehicle as `street_level`, `underground`, or `above`.

## Planned Second Model: Automatic Charging Decision

As a next step, we propose a second model responsible for the final decision: whether to initiate automatic charging.

This second model will take as input the output of the first model (especially `non_street_confidence`) along with real contextual map and parking data. These inputs may include whether the user is inside a known paid zone, distance to the nearest public road, distance to private areas, proximity to garages or buildings, and anonymized historical parking patterns.

The goal of the second model is to reduce ground-level false positives. For example, even if GPS indicates proximity to a paid public street, the system should avoid initiating charging if the vehicle is likely in a private garage, underground parking, elevated structure, or private area where payment does not apply.

An important part of this second model is using real map data and collective parking patterns. The system can learn typical public parking behavior on a given street segment. If most parked vehicles on that street follow a particular spatial pattern but a new vehicle appears clearly offset from that pattern, the system can infer the vehicle is possibly in a private garage, building entrance, or another area that does not correspond to paid public parking.

## Conclusion

In summary, the final pipeline would be:

1. The app collects phone sensor data.
2. The first model estimates the vehicle's vertical context.
3. The second model combines that result with map data and parking patterns.
4. The system computes a final confidence score for automatic charging.
5. If confidence is high, automatic charging may be initiated.
6. If confidence is low or ambiguous, the user can be prompted for confirmation instead of being charged automatically.

This two-model approach makes the system safer and less dependent on perfect GPS. The first model handles vertical context, while the second model makes the final charging decision using spatial context, real map data, and learned parking patterns.
