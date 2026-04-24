flowchart LR
    subgraph S1[" SOURCE · continuous "]
        direction TB
        POS([POS]):::source
        LAB([Labor]):::source
        RES([Reservation]):::source
    end

    subgraph S2[" STANDARDS · locks every 60 days "]
        direction TB
        FACTS([Canonical<br/>Facts]):::source
        BENCH([60-Day<br/>Benchmark]):::std
        TC([Target<br/>Cycle]):::std
    end

    subgraph S3[" PLAN · regenerates every week "]
        direction TB
        FC([Demand<br/>Forecast]):::plan
        WP([Weekly<br/>Plan]):::plan
        WP -.->|new plan auto-locks<br/>every business week| FC
    end

    subgraph S4[" OPERATE · live daily "]
        direction TB
        SH([Shift]):::live
        FS([Full Shift<br/>whole-day]):::live
        DP([Day Part<br/>lunch · dinner · late]):::future
        VAR([Variance]):::live
        SH --> FS
        SH --> DP
        FS --> VAR
        DP --> VAR
    end

    subgraph S5[" LEARN · closed truth "]
        direction TB
        HIST([History]):::learn
        LEARN([Learn]):::learn
    end

    POS --> FACTS
    LAB --> FACTS
    RES --> FACTS
    FACTS --> BENCH
    BENCH --> TC
    TC --> FC
    FC --> WP
    WP --> SH
    VAR --> HIST
    HIST --> LEARN
    LEARN -.->|learned patterns inform next cycle<br/>for that specific restaurant|TC

    classDef source fill:#F97316,stroke:#C2410C,stroke-width:2px,color:#fff,font-weight:bold
    classDef std fill:#0891B2,stroke:#155E75,stroke-width:2px,color:#fff,font-weight:bold
    classDef plan fill:#06B6D4,stroke:#0891B2,stroke-width:2px,color:#fff,font-weight:bold
    classDef live fill:#22D3EE,stroke:#0891B2,stroke-width:2px,color:#0c4a6e,font-weight:bold
    classDef learn fill:#155E75,stroke:#0c4a6e,stroke-width:2px,color:#fff,font-weight:bold
    classDef future fill:#0c4a6e,stroke:#A5F3FC,stroke-width:2px,stroke-dasharray:5 5,color:#A5F3FC,font-weight:bold

    style S1 fill:#2a1810,stroke:#F97316,stroke-width:1.5px,color:#F97316
    style S2 fill:#0a2530,stroke:#0891B2,stroke-width:1.5px,color:#22D3EE
    style S3 fill:#0a3540,stroke:#06B6D4,stroke-width:1.5px,color:#67E8F9
    style S4 fill:#0f4550,stroke:#22D3EE,stroke-width:1.5px,color:#A5F3FC
    style S5 fill:#061d26,stroke:#155E75,stroke-width:1.5px,color:#fff