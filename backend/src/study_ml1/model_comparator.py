import pandas as pd
import numpy as np
import warnings

# Scikit-Learn: Validation and preprocessing tools
from sklearn.model_selection import StratifiedKFold, cross_validate
from sklearn.preprocessing import StandardScaler, LabelEncoder

# Scikit-Learn: The classic 5 models
from sklearn.ensemble import RandomForestClassifier
from sklearn.linear_model import LogisticRegression
from sklearn.neighbors import KNeighborsClassifier
from sklearn.svm import SVC

# XGBoost
from xgboost import XGBClassifier

# Ignore convergence or deprecation warnings to keep terminal clean
warnings.filterwarnings('ignore')

def run_model_comparison():
    print("Loading synthetic dataset...")
    # 1. Load the data
    try:
        df = pd.read_csv('sensor_payloads_simulated.csv')
    except FileNotFoundError:
        print("Error: File 'sensor_payloads_simulated.csv' not found. Run the generator first.")
        return

    # 2. Feature selection (Only sensors that matter for vertical context)
    features = [
        'pressure_delta_hpa', 'pressure_variance', 
        'mag_variance_total', 'mag_distortion_score',
        'gnss_accuracy_m', 'hdop', 'satellite_count', 'gnss_signal_drop'
    ]
    
    X = df[features].copy()
    y = df['label_ground_truth']

    # Convert boolean column to integers (0 and 1)
    X['gnss_signal_drop'] = X['gnss_signal_drop'].astype(int)

    # 3. Critical preprocessing
    print("Preprocessing data (Scaling and Encoding)...")
    
    # Standardization: Required for SVM, kNN and Logistic Regression
    scaler = StandardScaler()
    X_scaled = scaler.fit_transform(X)
    
    # XGBoost requires text labels to be numbers (0, 1, 2)
    label_encoder = LabelEncoder()
    y_encoded = label_encoder.fit_transform(y)

    # 4. Initialize the 5 models
    models = {
        'Logistic Regression': LogisticRegression(max_iter=1000, random_state=42),
        'k-Nearest Neighbors': KNeighborsClassifier(n_neighbors=5),
        'Support Vector Machine': SVC(kernel='rbf', random_state=42),
        'Random Forest': RandomForestClassifier(n_estimators=100, random_state=42),
        'XGBoost': XGBClassifier(random_state=42, use_label_encoder=False, eval_metric='mlogloss')
    }

    # 5. Configure K-Fold Cross Validation
    # We use StratifiedKFold to ensure the 3 classes are well distributed across the 5 splits
    kfold = StratifiedKFold(n_splits=5, shuffle=True, random_state=42)
    
    # 6. Run training and evaluation
    print(f"\nStarting 5-Fold Cross Validation ({len(df)} samples)...\n")
    print(f"{'Model':<25} | {'F1-Score (Macro)':<20} | {'Accuracy':<15}")
    print("-" * 65)

    results = []

    for name, model in models.items():
        # The cross_validate function trains the model 5 times and returns test metrics
        cv_scores = cross_validate(
            model, 
            X_scaled, 
            y_encoded, 
            cv=kfold, 
            scoring=['f1_macro', 'accuracy'],
            n_jobs=-1 # Use all processor cores for speed
        )
        
        # Calculate the average of the 5 splits
        mean_f1 = np.mean(cv_scores['test_f1_macro'])
        std_f1 = np.std(cv_scores['test_f1_macro'])
        mean_acc = np.mean(cv_scores['test_accuracy'])
        
        # Store to sort later
        results.append({
            'Model': name,
            'F1': mean_f1,
            'F1_std': std_f1,
            'Acc': mean_acc
        })
        
        # Print line in real time
        print(f"{name:<25} | {mean_f1:.4f} (+/- {std_f1:.4f}) | {mean_acc:.4f}")

    print("-" * 65)
    
    # Identify the winner
    winner = max(results, key=lambda x: x['F1'])
    print(f"\nThe winning model is {winner['Model']} with an average F1-Score of {winner['F1']:.4f}!")

    # =====================================================================
    # METRICS OF THE WINNING MODEL
    # =====================================================================
    from sklearn.metrics import classification_report, confusion_matrix
    from sklearn.model_selection import cross_val_predict

    print(f"\nGenerating detailed report for Random Forest...")
    
    # We choose RF for deep analysis
    best_model = RandomForestClassifier(n_estimators=100, random_state=42)
    
    # cross_val_predict performs complete simulation: stores the prediction for each row
    # only when that row was in the test set (avoiding cheating)
    y_pred = cross_val_predict(best_model, X_scaled, y_encoded, cv=kfold, n_jobs=-1)

    print("\n" + "="*50)
    print("CLASSIFICATION REPORT")
    print("="*50)
    # The target_names use the LabelEncoder to translate numbers (0,1,2) back to actual names
    print(classification_report(y_encoded, y_pred, target_names=label_encoder.classes_))

    print("\n" + "="*50)
    print("CONFUSION MATRIX (Reality vs. Prediction)")
    print("="*50)
    
    cm = confusion_matrix(y_encoded, y_pred)
    classes = label_encoder.classes_
    
    # print the confusion matrix
    format_row = "{:>15} | {:>12} | {:>12} | {:>12}"
    print(format_row.format("ACTUAL \\ PREDICTED", classes[0], classes[1], classes[2]))
    print("-" * 60)
    for i, real_class in enumerate(classes):
        print(format_row.format(real_class, cm[i][0], cm[i][1], cm[i][2]))
    print("\n")

if __name__ == "__main__":
    run_model_comparison()