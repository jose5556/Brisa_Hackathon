import pandas as pd
import numpy as np
import warnings

# Scikit-Learn: Ferramentas de validação e pré-processamento
from sklearn.model_selection import StratifiedKFold, cross_validate
from sklearn.preprocessing import StandardScaler, LabelEncoder

# Scikit-Learn: Os 4 modelos clássicos
from sklearn.ensemble import RandomForestClassifier
from sklearn.linear_model import LogisticRegression
from sklearn.neighbors import KNeighborsClassifier
from sklearn.svm import SVC

# XGBoost
from xgboost import XGBClassifier

# Ignorar avisos de convergência ou depreciação para manter o terminal limpo
warnings.filterwarnings('ignore')

def run_model_comparison():
    print("A carregar o dataset sintético...")
    # 1. Carregar os Dados
    try:
        df = pd.read_csv('sensor_payloads_simulated.csv')
    except FileNotFoundError:
        print("Erro: Ficheiro 'sensor_payloads_simulated.csv' não encontrado. Corre o gerador primeiro.")
        return

    # 2. Seleção de Features (Apenas os sensores que importam para o contexto vertical)
    features = [
        'pressure_delta_hpa', 'pressure_variance', 
        'mag_variance_total', 'mag_distortion_score',
        'gnss_accuracy_m', 'hdop', 'satellite_count', 'gnss_signal_drop'
    ]
    
    X = df[features].copy()
    y = df['label_ground_truth']

    # Converter a coluna booleana para inteiros (0 e 1)
    X['gnss_signal_drop'] = X['gnss_signal_drop'].astype(int)

    # 3. Pré-processamento Crítico
    print("A pré-processar os dados (Scaling e Encoding)...")
    
    # Padronização: Obrigatório para SVM, kNN e Regressão Logística
    scaler = StandardScaler()
    X_scaled = scaler.fit_transform(X)
    
    # XGBoost exige que as labels de texto sejam números (0, 1, 2)
    label_encoder = LabelEncoder()
    y_encoded = label_encoder.fit_transform(y)

    # 4. Inicializar os 5 Modelos
    models = {
        'Regressão Logística': LogisticRegression(max_iter=1000, random_state=42),
        'k-Nearest Neighbors': KNeighborsClassifier(n_neighbors=5),
        'Support Vector Machine': SVC(kernel='rbf', random_state=42),
        'Random Forest': RandomForestClassifier(n_estimators=100, random_state=42),
        'XGBoost': XGBClassifier(random_state=42, use_label_encoder=False, eval_metric='mlogloss')
    }

    # 5. Configurar o K-Fold Cross Validation
    # Usamos StratifiedKFold para garantir que as 3 classes estão bem divididas nos 5 testes
    kfold = StratifiedKFold(n_splits=5, shuffle=True, random_state=42)
    
    # 6. Executar o Treino e Avaliação
    print(f"\nA iniciar 5-Fold Cross Validation ({len(df)} amostras)...\n")
    print(f"{'Modelo':<25} | {'F1-Score (Macro)':<20} | {'Acurácia':<15}")
    print("-" * 65)

    results = []

    for name, model in models.items():
        # A função cross_validate treina o modelo 5 vezes e devolve as métricas de teste
        cv_scores = cross_validate(
            model, 
            X_scaled, 
            y_encoded, 
            cv=kfold, 
            scoring=['f1_macro', 'accuracy'],
            n_jobs=-1 # Usa todos os cores do processador para ser mais rápido
        )
        
        # Calcular a média dos 5 testes
        mean_f1 = np.mean(cv_scores['test_f1_macro'])
        std_f1 = np.std(cv_scores['test_f1_macro'])
        mean_acc = np.mean(cv_scores['test_accuracy'])
        
        # Guardar para poder ordenar depois
        results.append({
            'Modelo': name,
            'F1': mean_f1,
            'F1_std': std_f1,
            'Acc': mean_acc
        })
        
        # Imprimir linha em tempo real
        print(f"{name:<25} | {mean_f1:.4f} (+/- {std_f1:.4f}) | {mean_acc:.4f}")

    print("-" * 65)
    
    # Identificar o Vencedor
    vencedor = max(results, key=lambda x: x['F1'])
    print(f"\n🏆 O Modelo Vencedor é o {vencedor['Modelo']} com um F1-Score médio de {vencedor['F1']:.4f}!")


    # =====================================================================
    # MERGULHO PROFUNDO: MÉTRICAS DO MODELO VENCEDOR (Random Forest)
    # =====================================================================
    from sklearn.metrics import classification_report, confusion_matrix
    from sklearn.model_selection import cross_val_predict

    print(f"\n🔍 A gerar relatório detalhado para o Random Forest...")
    
    # Escolhemos o RF para a análise profunda
    best_model = RandomForestClassifier(n_estimators=100, random_state=42)
    
    # cross_val_predict faz a simulação completa: guarda a previsão de cada linha 
    # apenas quando essa linha esteve no grupo de teste (evitando batota)
    y_pred = cross_val_predict(best_model, X_scaled, y_encoded, cv=kfold, n_jobs=-1)

    print("\n" + "="*50)
    print(" 📊 RELATÓRIO DE CLASSIFICAÇÃO")
    print("="*50)
    # O target_names usa o LabelEncoder para traduzir os números (0,1,2) de volta para os nomes reais
    print(classification_report(y_encoded, y_pred, target_names=label_encoder.classes_))

    print("\n" + "="*50)
    print(" 🧩 MATRIZ DE CONFUSÃO (Realidade vs. Previsão)")
    print("="*50)
    
    cm = confusion_matrix(y_encoded, y_pred)
    classes = label_encoder.classes_
    
    # Impressão bonita da Matriz de Confusão no terminal
    format_row = "{:>15} | {:>12} | {:>12} | {:>12}"
    print(format_row.format("REAL \\ PREVISTO", classes[0], classes[1], classes[2]))
    print("-" * 60)
    for i, real_class in enumerate(classes):
        print(format_row.format(real_class, cm[i][0], cm[i][1], cm[i][2]))

if __name__ == "__main__":
    run_model_comparison()