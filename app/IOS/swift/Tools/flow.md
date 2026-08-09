flowchart TD
    subgraph Recolha["1. Recolha Continuada"]
        A["<b>Início da recolha</b><br/>GPS, barómetro, magnetómetro"]
        B["<b>Buffer temporal</b><br/>Janela de 30s, histórico 180s"]
    end

    subgraph Processamento["2. Evento & Processamento Local"]
        C["<b>Toque do utilizador</b><br/>Estacionar / Analisar ambiente"]
        D["<b>Cálculo do SensorScore</b><br/>Deteta a transição"]
        E["<b>Determinação da janela</b><br/>Recua até ao baseline"]
        F["<b>Extração de features</b><br/>Agrega em SensorPayload"]
    end

    subgraph Servidor["3. Backend & Classificação"]
        G["<b>Envio ao backend</b><br/>POST /parking-events/analyze"]
        H["<b>Resultado + feedback</b><br/>Classificação, decisão, correção"]
    end

    A --> B
    B --> C
    C --> D
    D --> E
    E --> F
    F --> G
    G --> H

    %% Estilização personalizada para corresponder à imagem original
    style A fill:#e6f4ea,stroke:#1b5e20,color:#1b5e20,stroke-width:1px
    style B fill:#e6f4ea,stroke:#1b5e20,color:#1b5e20,stroke-width:1px

    style C fill:#ede7f6,stroke:#4a148c,color:#4a148c,stroke-width:1px
    style D fill:#ede7f6,stroke:#4a148c,color:#4a148c,stroke-width:1px
    style E fill:#ede7f6,stroke:#4a148c,color:#4a148c,stroke-width:1px
    style F fill:#ede7f6,stroke:#4a148c,color:#4a148c,stroke-width:1px

    style G fill:#fbe9e7,stroke:#bf360c,color:#bf360c,stroke-width:1px
    style H fill:#fbe9e7,stroke:#bf360c,color:#bf360c,stroke-width:1px