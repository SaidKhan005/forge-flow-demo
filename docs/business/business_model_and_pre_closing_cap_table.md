# Forge & Flow — Business Model and Pre-Closing Capitalization Table

Compiled from the existing Forge & Flow source documents only. Substantive
phrases are direct quotes from the source docs and shown in quotation marks.
Block names and table headings are taken from the two reference templates
(`business-model-canvas.pdf`, `Are-cap-tables-a-challenge.pdf`).

Source legend used throughout:
- **BP** — `Forge & Flow Business Plan.pdf`
- **PC** — `ForgeFlow Project Cost.xlsx`
- **PCS** — `ForgeFlow Project Cost Supporting Docs.pdf`
- **YP** — `ForgeFlow Yearly Projections.xlsx`
- **FT** — `ForgeFlow_Funding_Tracker.xlsx`
- **IP** — `IP Portfolio and Strategy.docx`
- **ET** — `forge_flow_engineering_timeline.docx`
- **BMC** — `business-model-canvas.pdf` (Strategyzer / BDC, template only)
- **Osler** — `Are-cap-tables-a-challenge.pdf` (template / structure only)

---

## Part A — Business Model Canvas

Designed for: **Forge & Flow** (BP, cover) — "98296 Newfoundland & Labrador Ltd." (IP, header).
Designed by: **Said Khan, Owner/Software Architect** and **Vanessa Gallegos Venegas, Owner/Business Development** (BP, "Our Leadership").

Block order follows the BDC canvas layout.

### 1. Key Partners (BMC block)

- "Jim Taylor, owner of Benchmark Sixty and host of Restaurant Canada's podcast" — "Since June 2025, we've nurtured a strong relationship with Jim, whose clients would be prime candidates for our solution." (BP, "Strategic Partnerships")
- "POS companies" — "establishing connections with POS companies can boost our visibility and provide strong advocates for our brand." (BP, "Strategic Partnerships")
- "complementary tech solutions" — "By integrating with complementary tech solutions, we can create comprehensive offerings that optimize operations for our clients." (BP, "Strategic Partnerships")
- POS transport: "Toast POS API" (PC, E04 Technologies Used; ET, May 11 - May 23 2026)
- Labor transport: "7shifts API" (PC, E04 Technologies Used; ET, May 11 - May 23 2026)
- Reservation transport: "OpenTable reservation transport" (ET, May 11 - May 23 2026); "Open Table integration" (BP, "Daily Board")
- Backend platforms: "Firebase Auth identity layer, Supabase Postgres data layer, and Google Cloud Run compute layer back-end" (IP, "Copyright")
- IP filing agent: "Heer Law as the IP agent for filing and legal review" (PCS, E14)
- Coaching: "Dan Martell's SaaS Academy - 12-month founder coaching program" (PCS, E16)
- Advisor: "Restaurant ops advisor (Jim Taylor)" (PC, E15)
- Security audit: "Astra Pentest / Bulletproof Solutions" (PC, E23; PCS, E23)
- Customer support tooling partners: "HelpScout customer support ticketing" (PCS, E29); "Time etc supplies vetted part-time virtual assistants" (PCS, E30)
- Sales / marketing platform: "HubSpot CRM Suite to track every lead, Mailchimp for email nurture, and Google plus LinkedIn plus Meta ads" (PCS, E11)
- Industry association: "Restaurants Canada" (FT, "Industry & Other")
- App-store distribution: "Apple Developer Program" and "Google Play Developer" (PCS, E28)

### 2. Key Activities (BMC block)

- "build the POS and labor integrations" (PCS, E04)
- "build the backend foundation" (PCS, E05)
- "build the user account and authentication layer using Firebase Auth, Firestore, and Firebase Admin SDK" (PCS, E06)
- "Phase 9: authentication via Firebase Auth, role-based permissions, Postgres Row-Level Security per-location isolation" (ET)
- "Phase 8 and 8R: live Toast POS, 7shifts Labor, and OpenTable reservation transport; canonical operational facts populated from real vendor APIs" (ET)
- "Phase 10a: Supabase shared multi-device state with Realtime sync, polling fallback, and audit trail" (ET)
- "Phase 11a Part 1: founder methodology corpus converted to Markdown and ingested into Apache AGE graph + pgvector store" (ET)
- "Phase 11b: stateless agent runtime and Forge & Flow manager chat UI with provenance surfacing" (ET)
- "Phase 9.8 compliance groundwork: privacy policy, ToS, DPAs drafted with legal counsel" (ET)
- "External security audit (RLS policy review, Firebase Auth config audit, per-operator isolation tests)" (ET, June 1 - June 13 2026)
- "App store final submissions, beta testing cycles, operator staff training" (ET, June 1 - June 13 2026)
- "Pilot restaurant cuts over to the production stack" (ET, June 15 - June 30 2026 milestone)

### 3. Key Resources (BMC block)

People (BP, "Our Leadership"):
- "Said Khan - Owner/Software Architect"
- "Vanessa Gallegos Venegas - Owner/Business Development"
- "Bhanupriya - Technical Sales Representative"

Intellectual property (IP, "Portfolio Summary"):
- "Copyright: The Company owns, by operation of the Copyright Act, the entire source code of the Forge & Flow mobile and backend application (Flutter and Dart front-end; Firebase Auth identity layer, Supabase Postgres data layer, and Google Cloud Run compute layer back-end), its user-interface designs, its founder-authored training and methodology content library, its marketing website, and all written collateral."
- "Trademarks: The Company has scoped and budgeted a filing of the 'Forge & Flow' word mark with the Canadian Intellectual Property Office (CIPO)."
- "Proprietary know-how and trade secrets: ... the 60-day standards-lock cycle, the runtime active-target projection, the separation of rolling demand forecasting from locked operating standards, the locked weekly-plan comparison model, the daypart pattern-evidence model, the recommended-benchmark selection statistics (including operating-performance-zone width thresholds and star-shift selection logic), and the connected knowledge-graph approach that powers the in-app advisor agent."
- "Domains and handles: The Company holds or will secure relevant domain names and social handles for the Forge & Flow brand."

Equipment and tooling (PC, "Equipment" + "Infrastructure"):
- "Vanessa and Priya work laptops" — "ASUS ROG Zephyrus G14 / Lenovo Legion Slim 5 (or equivalent)" (PC, E31)
- "MacBook (iOS app development)" — "MacBook Pro 14-inch M5 / Xcode" (PC, E32)
- "Dev-unlocked test phones (iOS + Android)" — "Samsung Galaxy A25 / iPhone 17e" (PC, E33)
- "Cloud hosting (Firebase Auth + Supabase + Cloud Run)" (PC, E24)
- "App monitoring + alerts" — "Sentry / BetterStack" (PC, E25)
- "Software development tools" — "GitHub / Figma / 1Password" (PC, E27)

### 4. Value Propositions (BMC block)

Mission (BP):
- "Creating innovative solutions that empower restaurant operators to spend more time on the floor and less time in the office."

Core proposition (BP, "Our Story"):
- "a unique KPI dashboard and learning center"
- "By harnessing 60 days of data, Forge & Flow calculates benchmark targets that empower operators to make informed, proactive decisions."
- "real-time insights that encourage a proactive approach to management"

Tab-by-tab (BP, "Tab Overview"):
- **SHIFT** — "comprehensive overview of live data for the day"; covers, daily sales vs forecast, PPA vs target, CPLH and SPLH vs targets, blended wage.
- **VARIANCE** — "comparison between theoretical or baseline expectations and actual performance across key performance indicators (KPIs)" with "history tab for tracking past data and a learn tab that offers valuable feedback on persistent leaks and repeatable wins."
- **PLAN** — "comprehensive weekly plan, which provides a detailed forecast for each day of the week" using "60 days of data from the Point of Sale (POS) system."
- **BENCHMARK** — "a clear benchmark for each Key Performance Indicator (KPI)"; "Every 60 days, your targets will shift."

Learning Management (BP, "Learning Management"):
- "an LMS into our app, providing staff with easy access to training materials, handbooks, and assessments"
- "Standard Operating Procedures (SOPs) ... Our app conveniently stores these SOPs, making them easily accessible to all staff members."

Chat Bots (BP, "Chat Bots"):
- "user-friendly chat bubble that floats seamlessly on the home screen of each location"
- "Unlike standard AI systems that isolate data into disconnected fragments, our app creates a connected web of relationships."

Communication / Team Board (BP):
- "DAILY BOARD," "ANNOUNCEMENTS," "FOCUS," "RECOGNITION," "COACHING."

Proactive Metrics (BP, "The Proactive Metrics"):
- "Covers Per Labor Hour (CPLH)"
- "Sales Per Labor Hour (SPLH)"
- "Per Person Average (PPA)"
- "Covers"
- "Blended Wage"
- "Table Turn Time"

Day Parts (BP, "The Impact Of Dayparts"):
- "Breaking down restaurant statistics into distinct day parts - lunch, dinner, and late night."

Customization (BP, "Superior User Experience"):
- "the option for customized branding allows restaurants to incorporate their own logos, colors, and photos ... while having the app named after their establishment."

### 5. Customer Relationships (BMC block)

- "one-on-one, in-person interactions" — "allows us to foster genuine connections with clients" (BP, "Higher Customer Acquisition Costs")
- "consultative, in-person approach" (BP, "Higher Customer Acquisition Costs")
- "by utilizing our own technology within our restaurant, we can directly demonstrate to owners how our app enhances both profitability and operational efficiency." (BP, "Higher Customer Acquisition Costs")
- Onboarding: "Includes Integrations, Customization, Training, and Implementation" (BP, "Product Pricing")
- Tier 1 support: "HelpScout customer support ticketing - gives every operator a single place to send questions and get help, with an SLA dashboard so no tickets fall through the cracks." (PCS, E29)
- Extended support: "Time etc supplies vetted part-time virtual assistants who handle Tier 1 customer support tickets - answering setup questions, processing routine issues." (PCS, E30)
- Pilot site visits: "Pilot customer site visits" (PC, E20)
- Data ownership: "the Company's terms of service reserve operator data to the operator, with per-location isolation at the database layer." (IP, "Data and customer-IP boundaries")

### 6. Channels (BMC block)

Marketing (PC, "Marketing"; PCS):
- "Marketing website" — "Webflow or Framer / SEO tooling" (PC, E07; PCS, E07)
- "App Store Optimization" — "App Radar (keyword research, competitor tracking, listing optimization)" (PC, E08; PCS, E08)
- "Product demo + training videos" — "Fiverr Pro (video production)" (PC, E09); "hosted on our social media channels, App Store and Google Play listings, and marketing website" (PCS, E09)
- "Trade show travel (2 people)" (PC, E10) and "Trade show trip (founder)" (PC, E19)
- "Sales + marketing platform + ads" — "HubSpot CRM Suite / Mailchimp / Google+LinkedIn+Meta Ads" (PC, E11; PCS, E11)
- "Sales materials" — "Vistaprint" — "one-pagers, branded folders, booth banners" (PC, E12; PCS, E12)
- "Paid acquisition reserve" (PC, E13)
- "Industry conference attendance" (PC, E21)

Distribution (PCS, E28):
- "Apple Developer Program - annual fee required to publish the iOS app in the App Store."
- "Google Play Developer - one-time registration fee required to publish the Android app in Google Play."

Network (BP, "Widespread Connection With Restaurants And Tech Solutions"):
- "active participation in conferences across Canada and the United States, we have cultivated a robust network of contacts."

### 7. Customer Segments (BMC block)

Primary segment description (BP, "Target Demographic"):
- "a diverse range of restaurants eager to select their preferred technology solutions."
- "operators currently committed to multiple tech solutions, perhaps locked into contracts."
- "high-level operators and clients of Benchmark Sixty - those who take a modern and proactive approach to data analytics within their establishments."
- "restaurants aiming to enhance their staff development."

Niche framing (BP, "Niche Market Targeting"):
- "Restaurants represent a unique niche market for technology solutions due to their distinct operational challenges, such as high labor and food costs, thin profit margins, and the necessity for rapid, multi-channel service."

### 8. Cost Structure (BMC block)

One-time project budget (PC, Category Summary; "TOTAL PROJECT $200,000 CAD | 34 line items"; "Entity: 98296 Newfoundland & Labrador Ltd"):

| Category | Total (CAD) |
|---|---|
| Salaries | 40,000 |
| Engineering Labor | 35,000 |
| Marketing | 31,200 |
| Professional Fees | 32,000 |
| Travel | 14,000 |
| Contingency | 22,200 |
| Security | 6,500 |
| Infrastructure | 7,150 |
| Support | 4,000 |
| Equipment | 6,450 |
| Insurance | 1,500 |
| **TOTAL PROJECT** | **200,000** |

Recurring "COST OF REVENUE" categories (YP, Summary):
- "Cloud Hosting & Infrastructure"
- "Third-Party API Fees (POS / Labor / Reservation)"
- "Payment Processing"
- "Customer Support"

Recurring "VARIABLE OPERATING EXPENSES" categories (YP, Summary):
- "Sales & Marketing" (Advertising - Physical, Advertising - Digital, "Sales Commissions ($100 per new paid customer)")
- "Research & Development" (Technology (Dev Tools), Software Licenses)
- "General & Administrative" (Office Supplies, Equipment, IT Support & Maintenance, Third-Party Services (CRM, Ticketing, Analytics), HR & Recruiting, Professional Fees, Travel, Training & Development)

Recurring "FIXED COSTS" categories (YP, Summary):
- "Salaries & Benefits (Base)" — Executive, Engineering, Sales, Customer Success, Operations
- "Insurance"

### 9. Revenue Streams (BMC block)

Pricing tiers (BP, "Product Pricing"):

| Tier | Description (verbatim) | Price (verbatim) |
|---|---|---|
| ONBOARDING | "Includes Integrations, Customization, Training, and Implementation. Onboarding cost determined by the amount of features, the number of solutions required for integration, and the difficulty of those integrations." | "$250-$1000" |
| BASIC PACKAGE | "KPI Dashboard, Back Office Reporting, Customized App With Up To Four Logins, Chatbot for Management, Automated Feedback For Managers" | "$250/Month" |
| PREMIUM PACKAGE | "KPI Dashboard, Back Office Reporting, Customized App, Chatbot for Management, Automated Feedback For Managers, LMS Platform, Employee Scoreboard and Performance Tracking" | "$250/Month +" "$5 Per User/Month For First 20 Users, $3 Each Additional User" |
| ELITE PACKAGE | "KPI Dashboard, Back Office Reporting, Customized App, Chatbot for Management and for Staff, Automated Feedback For Managers and for Staff, LMS Platform, SOP Templates, Training Manual Library, Employee Scoreboard and Performance Tracking" | "$250/Month +" "$7 Per User/Month For First 20 Users, $3 Each Additional User" |

Revenue lines tracked in projections (YP, REVENUE block, all five years):
- "Dashboard Subscription"
- "LMS Subscription"
- "Onboarding Fees"
- "Professional Services"

Discounts and allowances tracked against revenue (YP, "Less: Discounts & Allowances"):
- "Pilot Promotional Discounts"
- "Partner Referral Credits"
- "Early Adopter Credits"
- "Refunds & Credits"

---

## Part B — Pre-Closing Capitalization Table

Structure follows the "Main items" enumerated in `Are-cap-tables-a-challenge.pdf`
(Osler, Hoskin & Harcourt LLP, November 18, 2020). All populated values are
drawn verbatim from the Forge & Flow source documents; fields not addressed
by those documents are explicitly marked "Not specified in source documents."

### B.1 Issuer and date

- Legal entity name: "98296 Newfoundland & Labrador Ltd." (IP, header) — also stated as "Entity: 98296 Newfoundland & Labrador Ltd" (PC, "Cost Details" header).
- Stage descriptor: "Forge & Flow is a pre-launch SaaS company." (IP, "Portfolio Summary")
- Date prepared: "April 2026" (IP, header). Project budget snapshot "Prepared 2026-04-22" (PC, "Cost Details" header).

### B.2 Securities and their holders

Per Osler "Main items," a cap table lists "types of securities issued/granted/vested
(shares, options, warrants, convertible debentures, SAFEs, KISS)," "issue and grant
date, complete vesting schedules," and "name of each securities holder, and the
number and type of securities held by each."

| Holder (full legal name) | Type of security | Issue / grant date | Vesting schedule | Number of securities held | Purchase price paid per security / amount invested |
|---|---|---|---|---|---|
| Said Khan ("Owner/Software Architect" — BP, "Our Leadership") | Common shares (only securities class referenced; see B.3) | Not specified in source documents | Not specified in source documents | Not specified in source documents | Not specified in source documents |
| Vanessa Gallegos Venegas ("Owner/Business Development" — BP, "Our Leadership") | Common shares (only securities class referenced; see B.3) | Not specified in source documents | Not specified in source documents | Not specified in source documents | Not specified in source documents |

Per Osler "Approach," holders are listed by "the full legal name." The two
"Owner" titles above are the only equity-holder roles named in the source
documents. "Bhanupriya - Technical Sales Representative" (BP) is listed as
team but not as an owner.

Founder IP vesting note (IP, "Copyright hygiene and chain of title"):
"founder-to-company assignments so that all pre-incorporation development work
is formally vested in the Company."

### B.3 Total authorized shares (per class or series)

- Not specified in source documents.
- The only securities class referenced anywhere in the source corpus is the
  founder-held common-share position implied by the "Owner" titles (BP,
  "Our Leadership") and the "founder-to-company assignments" language (IP).
  No preferred class, series, warrants, debentures, SAFEs, or KISS are
  recorded as issued.

### B.4 Total issued and outstanding shares (fully diluted and basic)

- Not specified in source documents.
- "Patents issued: None. Patents pending: None." is stated in IP for patent
  counts; an analogous count for shares is not stated in the source corpus.

### B.5 Options reserved pool

- No employee or director option pool is referenced in the source
  documents. Per Osler the cap table assesses "whether the company has
  sufficient shares available for the option pool"; that determination
  cannot be made from the current corpus.

### B.6 Convertible securities (debentures, SAFEs, KISS)

- **Outstanding at the date of this table:** None referenced in source documents.
- **Prospective / under exploration** (FT, "Top Priorities" and "Atlantic Canada & Newfoundland"):
  - "Nventure thriveFORWARD" — "Convertible Note (pre-seed / seed)" — "NL tech; sector fit (verify for SaaS)" — Priority **HIGH** — Cash Flow **Upfront** — Status **In Progress**.

### B.7 Conversion formulas and mechanisms

- Not specified in source documents.

### B.8 Pre-money and/or post-money valuation

- Not specified in source documents.
- Per Osler ("Value of the company"): "Determining how much the company
  is worth may prove to be rather difficult, especially when the company is
  based on a good idea but few assets (like most biotech, life science or AI
  start-ups). In such cases, valuation becomes a subject of negotiation
  between the company and the investors."

### B.9 Ownership, control, voting and participation percentages

- Not specified in source documents. Per Osler, these percentages are
  derived once "the number and type of securities held by each" (B.2) and
  "total number of issued and outstanding shares" (B.4) are populated;
  both are currently unsourced in the corpus.

### B.10 Approval thresholds and proxy participation

- Not specified in source documents (no shareholders' agreement or
  articles of incorporation language is quoted in the existing corpus).

### B.11 Sources of funds (debt-side and owner-contribution; contemplated)

These are not equity issuances but are recorded as the Company's planned
capitalization counterparts to the project budget. Verbatim from PC,
"Sources of Funds":

| Source | Amount (CAD) |
|---|---|
| "Bank Term Loan (Interest-only Y1-Y2, 5-yr amortization)" | 200,000 |
| "Owner Contribution (personal savings)" | 60,000 |
| "Existing Line of Credit (working capital reserve)" | 30,000 |
| **TOTAL SOURCES** | **290,000** |

Project use-of-funds total against the above (PC, Category Summary):
"TOTAL PROJECT 34 line items: 200,000."

In-flight debt instruments tracked in the funding tracker (FT, "Loans & Debt"):
- "Women Entrepreneurship Organizations of Canada (WEOC) Loan Fund" — "Up to $50,000 (average $15,000)" — Status **Submitted**.
- "Canada Small Business Financing Program" — "Up to $1,000,000 ($500K equip; $150K WC)" — Status **In Progress**.

### B.12 Prospective external capital sources tracked by the Company

Verbatim from FT, "Directory Summary":

| Category | Sources |
|---|---|
| Grants & Tax Credits | 18 |
| Loans & Debt | 9 |
| Angel Networks | 7 |
| Venture Capital | 17 |
| Startup Programs | 9 |
| Industry & Other | 6 |
| Atlantic Canada & Newfoundland | 16 |
| **TOTAL** | **82** |

VERY HIGH priority items currently progressed (FT, Status column other than "-"):
- "Women Entrepreneurship Organizations of Canada (WEOC) Loan Fund" — **Submitted**.
- "Newfoundland and Labrador Organization of Women Entrepreneurs (NLOWE)" — **Reached Out**.
- "Canada Small Business Financing Program" — **In Progress**.
- "Nventure thriveFORWARD" — **In Progress**.

---

## Cross-references back to the templates

- BMC nine-block layout: `business-model-canvas.pdf` (Strategyzer / BDC).
- Cap-table "Main items" enumeration, "Approach" formatting rules
  (full legal names, defined terms, legend), and "Value of the company /
  Pre-money / Post-money valuation" framing: `Are-cap-tables-a-challenge.pdf`
  (Osler, Hoskin & Harcourt LLP, November 18, 2020).
