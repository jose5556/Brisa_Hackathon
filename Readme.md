## Visão Geral do Produto

O objetivo do sistema proposto é apoiar uma decisão automática sobre se deve ou não ser iniciada uma cobrança de estacionamento baseada em propabilidade.

Em vez de depender apenas da posição GPS, o sistema segue uma abordagem baseada em confiança. Ou seja, a cobrança automática só deve ser iniciada quando o sistema tiver confiança suficiente de que o carro está estacionado numa zona pública e que o pagamento é aplicável.

## Arquitetura do Sistema e Implementação

A nossa arquitetura começa numa aplicação Android desenvolvida em Kotlin. A aplicação recolhe dados reais do telemóvel durante uma janela de observação fixa de 10 segundos. Durante esse intervalo, são recolhidos sinais como a precisão do GPS, a perda de sinal GPS, a variação de altitude, a pressão atmosférica e as redes Wi-Fi próximas visíveis.

Depois da recolha, os dados brutos são transformados localmente, dentro da aplicação, em features agregadas, como `gps_accuracy_mean`, `gps_lost_ratio`, `pressure_delta`, `altitude_delta`, `vertical_change_abs` e `stationary_ratio`. Este passo é importante porque a aplicação não envia dados sensíveis em bruto, como nomes de redes Wi-Fi, identificadores Bluetooth ou localização contínua. Em vez disso, envia apenas valores estatísticos úteis para o modelo, seguindo uma abordagem de minimização de dados e privacidade desde a conceção.

De seguida, a aplicação envia estas features em formato JSON para uma API construída com FastAPI. A API recebe os valores, organiza-os pela mesma ordem usada durante o treino do modelo e passa-os ao nosso modelo de Machine Learning.

O modelo implementado é um `RandomForestClassifier`, treinado para distinguir três contextos verticais: `street_level`, `underground` e `above`. Internamente, o modelo calcula a probabilidade de cada uma destas classes. Para a decisão principal, somamos as probabilidades de `underground` e `above`, porque, em ambos os casos, o carro não se encontra numa via pública normal ao nível da rua. Assim, obtemos um valor chamado `non_street_confidence`, entre 0 e 1.

Por fim, a API devolve dois valores à aplicação: o `non_street_confidence`, que representa a probabilidade de o carro não estar ao nível normal da rua, e a `classification`, usada para depuração, que indica se o modelo considera que o carro está em `street_level`, `underground` ou `above`. A aplicação mostra este resultado ao utilizador em tempo real.

## Segundo Modelo Planeado: Decisão de Cobrança Automática

Como próximo passo, propomos um segundo modelo responsável pela decisão final: iniciar ou não a cobrança automática.

Este segundo modelo receberia como entrada o resultado do primeiro modelo, especialmente o `non_street_confidence`, juntamente com dados reais de contexto do mapa e do estacionamento. Estes dados poderiam incluir se o utilizador está dentro de uma zona paga conhecida, a distância à via pública mais próxima, a distância a zonas privadas, a proximidade de garagens ou edifícios e padrões históricos de estacionamento anonimizados.

O objetivo deste segundo modelo seria reduzir falsos positivos. Por exemplo, mesmo que a localização GPS pareça estar próxima de uma rua pública paga, o sistema deve evitar iniciar a cobrança se o carro estiver provavelmente numa garagem privada, num parque subterrâneo, numa estrutura elevada ou numa zona privada sem pagamento.

Uma parte importante deste segundo modelo seria o uso de dados reais de mapa e de padrões coletivos de estacionamento. O sistema poderia aprender como é normalmente o estacionamento público num determinado segmento de rua. Se a maioria dos carros estacionados nessa rua aparecer alinhada num determinado padrão espacial, mas um novo carro surgir claramente deslocado desse padrão, o sistema pode inferir que esse carro está possivelmente numa garagem privada, numa entrada de edifício ou noutra zona que não corresponde a estacionamento público pago.

## Conclusão

Em suma, a pipeline final seria:

1. A aplicação recolhe dados dos sensores do telemóvel.
2. O primeiro modelo estima o contexto vertical do carro.
3. O segundo modelo combina esse resultado com dados de mapa e padrões de estacionamento.
4. O sistema calcula uma confiança final para cobrança automática.
5. Se a confiança for alta, a cobrança pode ser iniciada automaticamente.
6. Se a confiança for baixa ou ambígua, o utilizador pode receber uma confirmação em vez de ser cobrado automaticamente.

Esta abordagem com dois modelos torna o sistema mais seguro e menos dependente de uma localização GPS perfeita. O primeiro modelo resolve o problema do contexto vertical, enquanto o segundo modelo trataria da decisão final de cobrança, usando contexto espacial, dados reais de mapa e padrões aprendidos de estacionamento.
