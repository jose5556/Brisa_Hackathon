import pandas as pd
import numpy as np
import warnings
from sklearn.model_selection import StratifiedKFold
from sklearn.preprocessing import StandardScaler, LabelEncoder
from sklearn.ensemble import RandomForestClassifier
from sklearn.linear_model import LogisticRegression
from sklearn.neighbors import KNeighborsClassifier
from sklearn.svm import SVC
from xgboost import XGBClassifier
from sklearn.metrics import classification_report, confusion_matrix

# Ignorar warnings
warnings.filterwarnings('ignore')

def label_trajectory_time(t):
    """
    Define a etiqueta Ground Truth (ML1) baseado no tempo da trajetória (segundos):
    - 0s a 270s: Condução na rua (Ponte -> Picaria -> Silo Auto Entrada) -> street_level
    - 270s a 330s: Subida e topo do Silo Auto (Estrutura elevada) -> above
    - 330s a 570s: Driving to Alameda (Via pública / VCI) -> street_level
    - 570s a 615s: Entrada e paragem no Alameda Subterrâneo -> underground
    """
    if 0 <= t < 270:
        return 'street_level'
    elif 270 <= t < 330:
        return 'above'
    elif 330 <= t < 570:
        return 'street_level'
    else:
        return 'underground'

def build_features_from_trajectory():
    print("A carregar o histórico de trajetória contínua...")
    try:
        raw_df = pd.read_csv('trajectory_OPO_data.csv')
    except FileNotFoundError:
        print("Erro: Executa primeiro o teu script 'trajectory_OPO.py' para gerar o CSV de dados!")
        return None

    window_size = 60  # Janela deslizante de 60 segundos
    step = 1          # Deslocamento de 1 em 1 segundo para gerar mais amostras
    
    processed_samples = []
    
    print(f"A fatiar a trajetória em Janelas Deslizantes de {window_size}s...")
    
    # Percorrer a série temporal contínua
    for start_t in range(0, len(raw_df) - window_size, step):
        end_t = start_t + window_size
        window = raw_df.iloc[start_t:end_t]
        
        # O estado final (no segundo exato da paragem sugerida) dita o Ground Truth
        final_timestamp = window.iloc[-1]['Timestamp_s']
        label = label_trajectory_time(final_timestamp)
        
        # === ENGENHARIA DE FEATURES NA JANELA DE 60 SEGUNDOS ===
        
        # 1. Barómetro
        pressure_series = window['Barometer_hPa'].values
        pressure_delta_hpa = pressure_series[-1] - pressure_series[0]
        pressure_variance = np.var(pressure_series)
        
        # 2. Magnetómetro
        mag_x = window['Magnetometer_X_uT'].values
        mag_y = window['Magnetometer_Y_uT'].values
        mag_z = window['Magnetometer_Z_uT'].values
        
        mag_variance_total = np.var(mag_x) + np.var(mag_y) + np.var(mag_z)
        
        # Cálculo de Distorção Magnética (Desvio médio em relação a 44 uT típico do Porto)
        mag_vector = np.sqrt(mag_x**2 + mag_y**2 + mag_z**2)
        mean_mag = np.mean(mag_vector)
        mag_distortion_score = np.clip(abs(mean_mag - 44.0) / 44.0, 0.0, 1.0)
        
        # 3. GNSS / GPS (Invenção de métricas de qualidade baseadas no GPS_Status simulado)
        gps_status_series = window['GPS_Status'].values
        gnss_signal_drop = 0 in gps_status_series # Teve quebras?
        
        # Se perdeu o sinal, simula a degradação de precisão e satélites
        if gnss_signal_drop:
            gnss_accuracy_m = 45.0
            hdop = 8.0
            satellite_count = 2
        else:
            gnss_accuracy_m = 6.0
            hdop = 1.2
            satellite_count = 14
            
        # Adicionar ao nosso dataset estruturado
        processed_samples.append({
            'pressure_delta_hpa': pressure_delta_hpa,
            'pressure_variance': pressure_variance,
            'mag_variance_total': mag_variance_total,
            'mag_distortion_score': mag_distortion_score,
            'gnss_accuracy_m': gnss_accuracy_m,
            'hdop': hdop,
            'satellite_count': satellite_count,
            'gnss_signal_drop': int(gnss_signal_drop),
            'label_ground_truth': label
        })
        
    df_features = pd.DataFrame(processed_samples)
    print(f"Dataset de treino gerado! Total de amostras temporais: {len(df_features)}")
    return df_features

def evaluate_models_on_trajectory():
    df = build_features_from_trajectory()
    if df is None:
        return
        
    features = [
        'pressure_delta_hpa', 'pressure_variance', 
        'mag_variance_total', 'mag_distortion_score',
        'gnss_accuracy_m', 'hdop', 'satellite_count', 'gnss_signal_drop'
    ]
    
    X = df[features]
    y = df['label_ground_truth']
    
    scaler = StandardScaler()
    X_scaled = scaler.fit_transform(X)
    
    label_encoder = LabelEncoder()
    y_encoded = label_encoder.fit_transform(y)
    
    # Os mesmos 5 modelos que estudámos (Sintaxe do XGBoost corrigida aqui)
    models = {
        'Regressão Logística': LogisticRegression(max_iter=1000, random_state=42),
        'k-Nearest Neighbors': KNeighborsClassifier(n_neighbors=5),
        'Support Vector Machine': SVC(kernel='rbf', random_state=42),
        'Random Forest': RandomForestClassifier(n_estimators=100, random_state=42),
        'XGBoost': XGBClassifier(random_state=42, use_label_encoder=False, eval_metric='mlogloss')
    }
    
    kfold = StratifiedKFold(n_splits=5, shuffle=True, random_state=42)
    
    print(f"\nA avaliar os modelos na trajetória de Porto (OPO)...")
    print(f"{'Modelo':<25} | {'F1-Score (Macro)':<20} | {'Acurácia':<15}")
    print("-" * 65)

    for name, model in models.items():
        from sklearn.model_selection import cross_val_score
        scores_f1 = cross_val_score(model, X_scaled, y_encoded, cv=kfold, scoring='f1_macro', n_jobs=-1)
        scores_acc = cross_val_score(model, X_scaled, y_encoded, cv=kfold, scoring='accuracy', n_jobs=-1)
        print(f"{name:<25} | {np.mean(scores_f1):.4f} | {np.mean(scores_acc):.4f}")
        
    # Análise profunda do Random Forest na trajetória
    from sklearn.model_selection import cross_val_predict
    rf = RandomForestClassifier(n_estimators=100, random_state=42)
    y_pred = cross_val_predict(rf, X_scaled, y_encoded, cv=kfold, n_jobs=-1)
    
    print("\n" + "="*50)
    print(" 📊 RELATÓRIO DE CLASSIFICAÇÃO NA TRAJETÓRIA REAL (OPO)")
    print("="*50)
    print(classification_report(y_encoded, y_pred, target_names=label_encoder.classes_))
    
    print("\n" + "="*50)
    print(" 🧩 MATRIZ DE CONFUSÃO DA TRAJETÓRIA")
    print("="*50)
    cm = confusion_matrix(y_encoded, y_pred)
    classes = label_encoder.classes_
    
    format_row = "{:>15} | {:>12} | {:>12} | {:>12}"
    print(format_row.format("REAL \\ PREVISTO", classes[0], classes[1], classes[2]))
    print("-" * 60)
    for i, real_class in enumerate(classes):
        print(format_row.format(real_class, cm[i][0], cm[i][1], cm[i][2]))

if __name__ == "__main__":
    evaluate_models_on_trajectory()
