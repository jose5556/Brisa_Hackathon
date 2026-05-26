import pandas as pd
from sklearn.model_selection import train_test_split
from sklearn.ensemble import RandomForestClassifier
from sklearn.metrics import classification_report, confusion_matrix
import joblib

# 1. Load Data
df = pd.read_csv('parking_data.csv')
X = df[['baro_delta', 'gyro_energy', 'gps_snr_drop']]
y = df['label']

# 2. Split
# test_size=0.2 means 20% of the data will be used for testing, and 80% for training
X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.2, random_state=42)

# 3. Train
model = RandomForestClassifier(n_estimators=100, max_depth=3, random_state=42)
model.fit(X_train, y_train)

# 4. Evaluate
predictions = model.predict(X_test)
print("Confusion Matrix:")
print(confusion_matrix(y_test, predictions))
print("\nClassification Report:")
print(classification_report(y_test, predictions, target_names=['Street', 'Surface_Garage', 'Subterranean']))

# 5. Save model for App deployment
joblib.dump(model, 'parking_classifier.pkl')