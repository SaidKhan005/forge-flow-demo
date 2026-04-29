<!-- converted from barrio_staff_companion.docx -->

# Barrio V1.1
## The Goal:
- Barrio gets a staff-facing side so staff are drawn to it more often. Therefore, being exposed to material more often and being incentivised to learn and grow with us.
- Forge & Flow stays the commercial manager’s tool. My though process: Variance Data from Forge and Flow can be used at the staff level to coach motivate inspire.
- Staff open Barrio every day before their shift to get ready for work and after their shift to see how they performed.
- Opportunity for AI driven Coaching and teaching, Derived from restaurant’s training content and restaurant data.
- Forge and flow learning.
## What’s New on the Barrio Home Screen
Two new bubbles appear on the home screen: (User interface chang is simple later if it’s not practical)
### Team Board: the team’s shared bulletin board
### Inside:
- Daily Board tab: Manager posts tonight’s need-to-knows what’s 86’d, tonight’s specials, VIP arrivals, service notes. Staff reads it. Shows the last 3 days so you can scroll back. Also shows how busy tonight will be based on forecast covers and covers in the books via Open Table integration.
- Announcements tab: Longer posts from the manager (policy changes, menu rollouts, events). Stays up for 2 weeks. You can see if you’ve read it, manager can see who’s read what. Same as an Instagram/messenger message read recipient. A manager can pin an announcement and that will show up for everyone under my shift (my shift covered below)
- Focus tab: One thing the whole team is working on this week (e.g., “upsell appetizers”). Manager Gets help picking it based on last week’s variance and our training material; Also allowed to type their own
- Recognition tab (Managers only) gives shout-outs to staff. You earn badges like “Weedwhacker” or “problem solving pro” Your badge collection lives in El Podio and gives extra points towards the podium position. We can run staff incentives off El Podio
- Coaching Dashboard tab (managers only) Compares Variance to staff 1:1 to show who needs the most support this week. Then same as before, Manager Gets help picking coaching moments based on our training material; Also allowed to type their own

### 2. Schedule (staff schedule)
- My Shift: your pre-shift briefing and post-shift recap (more detail below)
- Personal Trends: your performance over time: sales numbers, coaching history, streaks. You see your own real numbers and how they compare to the restaurant benchmarks/targets.
- My Schedule -> push integration
- Daily Schedule -> push integration
- Hours Worked -> push integration
- Availability, Shift Swaps, Shift Releases -> push integration
## Details on My Shift: What Staff Sees Before and After Work
### Before your shift (pre-shift view)
- Your shift time and role with tonight’s goal “Your goal tonight: beat $42 PPA (you averaged $39 last week)”
- How busy tonight will be a card saying “Busy Night” with cover count (forecast + reso) if you tap it
- Important announcements from the manager: The pinned Item from Manager Announcement.
- This week’s focus: the one thing the team is working on
- Coaching tip for tonight: Either the 1:1 coaching tip the manager set if available or same logic routing where AI compares Variance to staff 1:1 to add a coaching moment based on our training material with a reason why it works. Want to try something different? Tap “show me another” for a different suggestion based on your patterns and personal trends, again linked to the bigger AI matrix for context.

### After your shift (post-shift view) (Note to self: Notification Trigger == Push clock out time stamp)
- You get a push notification saying “Your shift recap is ready”
- See how the night went sales vs target, covers served, broken down by dayparts etc,
- A verdict on weekly focus goal: did you hit it, get close, or miss it? -> If weekly focus == metric driven then compare. If focus == behaviour driven, then reiterate weekly focus for emphasis.
- A verdict on your Coaching tip:  did you hit it, get close, or miss it?
- Hitting these 2 goals earns points towards elpodio.
### On days you’re not working
- My Shift shows “No shift today” and when your next shift is
## AI Coach Chatbot (Coming later).
- A chat bubble floating on the Barrio home screen
- Staff can ask questions like “Why was my PPA low?” and get answers based on the restaurant’s training content and restaurant data
- Shows suggested questions by default, but you can type your own
- Managers get a different version (more permission); e.g helps with P&L summaries, explaining variances, draft letter of termination, (Always uses us)

## AI Explanation:
## NON-TECHNICAL (“It’s like a web” You explaining metrics got me thinking lol)
## The assistant doesn't just know facts about your restaurant it understands how your restaurant works. Standard AI systems store information as isolated chunks and retrieve the closest match to your question. We store everything as a connected web of relationships (the web I showed you) shifts connected to managers, managers connected to locations, locations connected to labor baselines, baselines connected to Jim Taylor's methodology. These methodologies connected to our training. When a manager asks a question, the assistant doesn't just find similar text, it traverses those connections to build a complete, contextually aware answer. So, when you ask, "is Sarah performing well?" it doesn't just pull Sarah's last shift. It looks at her SPLH across every shift, compares it to the location baseline, benchmarks it against other FOH staff, and measures it against our target methodology. So not just another Ai for restaurants.
## One line: assistant that retrieves information VS one that genuinely understands your operation.
In terms of application, you can do chatbots, then agents then workflows. In any way that you think will help.
## TECHNICAL (Note to self: 3 system layer)
- RAG (Retrieval Augmented Generation): our training data, Jim Taylor's methodology, Preston lee methodology. operator SOPs, and location baselines are stored in a knowledge graph where relationships between entities are explicitly modelled as nodes and edges. Shifts connect to managers, managers connect to locations, locations connect to labor baselines, baselines connect to methodology. When a query comes in the system traverses that graph, pulls the most relevant connected context, and passes it to the agentic model (e.g gpt 5, what chat gpt uses) as background knowledge.
- Tools: Handle your live and historical operational data including CPLH, SPLH, POS data, etc. fetched in real time during the agentic loop. The agentic model calls these tools dynamically based on what the question requires, not on a hardcoded sequence.
- The agentic model: Reasons over both the retrieved graph knowledge and the live tool data to generate an answer grounded in your restaurant's world. The agentic model never permanently stores any of your data. Every query assembles the right context fresh from our own infrastructure, meaning each operator's data stays fully isolated and private. The agentic model reasons over it, returns the answer, and retains nothing.