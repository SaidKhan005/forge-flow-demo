# All of this is the desired outcome for ux and end to end wiring: Hierachy and longer sections need to be area of focus. All of it need to be contracted out, accomplished, tested and dubged.
# The plan is we go through all this, we plan, we research online on best ux practices and code practice, you read it back to me in plain english,
    Then we zoom out and see end to end what code changes we need to make. we launch multiple agents across all layers of the architecture to make sure nothing is missed in implementation planning, use the feature framework as a guidelinE for what code seams not to miss. Then once we know what we are going to do we save it in a multiple docs that will allow for parallel split execution between codex and claude.
    The way i run it is I instruct the main to launch multiple agents working parallel in worktrees, assign tasks, audit against contracts, send back with bugs and gaps then auto commit and merge with origin. Claude and codex both do this. 

    Once we have the docs and slices we launch multiple agents in relation to the full plan to check our current code health and the various flags that have been raised in the repo docs about monoliths, tight coupling and areas that need to be refactored.
    We create the same type of planned docs for this. We update the project tracker.
    Then you give me 2 prompts, 1 for Codex to launch it's lane of code health and the rest of its implementation
    and the second for claude to do the same.
    In the end I would have 1 index doc/ have the project tracker as the index, then a claude and codex doc also indexed to all its lanes and contracts so the prompts can have full context through out.
    The goal is to execute the code health first fully end to end and then we begin tackling these features on a solid base and grounded on healthy engineering standard code


# Bugs
I got the proxy returned an incomplete session record sign in after support check proxy
Proxy crashed after somtime why did this happen can we debug
we will need to do time pressure test. live usage for hours and multiple sessions


# Hierachy
-----------------------------------------------------------------------------------------------
The rule has to be every single bit of infomantion or functionlity on the screen has to be wired this way end to end and has to be presented in the ux in the same exact consistent way. 
We need to zoom out and create a master list for this and an end to end implementation plan
Look at the items below for some of the functionality that needs to be following the hierachy system and the inheritance system where relevant.
----------------------------------------------------------------------------------------------------------------------------------
# Roles and permissions
I want you to do an audit of permissions and roles; What capabilities have currently been implemeted, exposed in the user interfaces, and where have they been exposed?
What roles are seeded. What capabilities do those roles carry. Is the rebac relationship based access control implemented. In all the phases and docs is role functionality fully done if not it has to be done now. 
I would like to decide and to adjust standard seeded roles These will then be the default roles that every business created will inherit. 
Based on the audit and what is going to be fully exposed for roles, Can you suggest seeded roles and functionality and previlages, Look through what the current seeded roles are.
Are roles applied the same way as the hierachy state is for busines functionality, when setting up roles and applying at different hierchy levels what does that look like in terms of inheritance and in the ux, does it match the rest of the hierachy scope functions and is it wired end to end.
I want in implementation end to end the Role name to be used to Populate the role key (can be unique to a business or in their hierachy or whatever but it has to eb auto populate and not user prompted in any ux) (what are the implications of this role key?) How do we differentiate location and business roles and make sure there is no overlap unless role is seeded
Across all ux elements in all mobile, and web consoles, rename seeded roles to Default roles.
For the roles display after creation or default roles i want to to only show the name and a short description. nothing else no other lables or writing just simple name and shrt description and an edit role button, Important For my default roles I want the ability for me in the admin console only to select it and adjust its permissions across the entirety of forge and flow. and then this in itself should be a permission.
For the invite team member the location assignment needs to change to the new hierachy type assignment
for the role list, instead of the 3 dot icon is should be a button saying edit user. We need to add an implementation here to be able to change their email address, name and adjust their role all this needs to not only be ux but we need to zoom out and make sure to implement it fully end to end also being able to change the hierachy there are in same thing end to end and the ux needs to show this hierachy cleanly
There needs to be a role and permission to access the ops console and the admin console under product access so for example operator manager and owner can acess te ops console and the admin console but cannot access the admin console and regualar restauraunt staff by default cannot access either, 
Then for the operator admin they can only permint and give permissions within their scope so a f&f admin can see all permission types but an owner only sees those assingned to them and ediatble by them
The roles themselves need to be categorized, I am thinkin by product, and then by functionality within each product. so if you select a product it auto populates to everyhthing in that product then you can add or delete, and then if you add a specific one that is dependant on another then that also adds in automatically, eg adding benchmark adjustment capability then the forge and flow product auto selects if it was not selected intially 
benchmark override ability (managers can only do once) and the admin being able to undo the override this should be a role, We also need a ux in the mobile and both web consoles under data accuracy to be able to adjust and cancel the overrride for it to be redone.
For pending invites we need a button to cancel the invite, Same thing this need to be wired in fully end to end and make sure it actually triggers the firebase api and everything else end to end zoom out for this too
the implementation requests above for team members and roles apply to both consoles unless specified other wise

---------------
# Profile 
your own profile needs the ability to change all the users own details and this needs to be wired in fully end to end.
remove the subtititle display name email...
The logic is to change account details here and not in the mobile app. This needs to be wired and implemented fully end to end with all user details.
This needs to be implemeted fully end to end and ux adjsueted for both the web consoles
The enroll MFA needs to be wired in fully
The same my account tab needs to be there on both the operator web console and admin webconsole for that specific user, currently the admin console does not have this

# audits and logs
------------------------------
Same hierachy logic should apply to audit hash and hash chains/ log chains; This enable better log filtering. 

# Emails and notifications -> Brian Computer.
--------------------------------------------------------------------------

Do a deep pressure test for all emails and notifications on the live connected device, the opertor and admin console where applicable.
Go through all email scenarios and all notification scenarios. 
Go through all the actions prompted by all the email and notification scenarios and pressure test all use cases, edge cases.
some example are password reset and the rest of the emails loopback back to the app/relevant console. Invite emails and that full setup. Mfa notifications push mark as read the icon on the notification bell does that update?
These example are not coclusive, Begin with an audit of all cpabilities available first before planning and executing these tests. Nothing missed. 
During the pressure tests if any bugs and gaps arise make sure to dubug and fix as we go and test again.
Work in multiple work trees with parallel agents, stand as the auditor and send back bugs. auto push, pr and merges are allowed once results are satisfactory and fully tested.

-----------------------------------------------------
## Admin console UX
---------------------------------------------
For Roles:
What actor and actor kind labels do we use we need to focus on making this more user or restauraunt friendly,

In terms of user interface; this is a problem statemet i want to audit and address "The product rule should be something like:
If a role can manage team members, it should include team.users.view.
If a role can create/edit roles, it should probably include team.roles.view and team.users.view.
If a role can assign roles, it should include team.roles.view and enough user visibility to choose targets.
If a role is location-scoped, the UI should make clear that org-wide/operator-wide actions will not be available.
Custom roles should be editable, but the editor should prevent or warn about “orphan” permission combos that technically grant an action but hide the surface needed to use it.

---------------------------------------
# Questions:
Do an audit on code vs docs to make sure that anything that is not paused is implemented fully end to end across all seams of the architecture and there is no code scaffold at all
what is the sql lite refresh rate -> the rule is the dashboard on the phone needs to be as live as vendors allow for polling and as live as vendors send webhooks
what event and realtime is configured from the architecture md

---------------------------------------
# Implementation details:
Can we turn the framework docs we have under frameworks and organize them into runbooks for use to use, Update references in project tracker and claude md
Can we have scripts for automation, we can run constantly to our workflow including the clean up and archiving tasks we do, the debugging and auditing against contracts and doc for each agent work done, 
We need a proper system to handle schema versioning and migrations systematically so nothing is lost for our users
we need an audit on our data models, overfetching, synchoronous bottlenecks, no caching, bead indices, no of expensive fetches and anything else that will hinder our architecture perfromance
can we audit proxy health and have that as a ui under the system health tab

once happy with all functionality and ux update and run all tests group them let them be conclusive and cover everything same for git workflow tests
begin sop's
begin vendor outreach

-------------------------------------------------------------
## Ops Console Ux
-----------------------
0)  Login screen:
Get rid of the green sign in logo/icon
get rid of the subtitile: use the same forge & flow operator account...
    Top bar:
    The top bar needs to be bigger the admin sign out and the useremail can be bigger and the loction selector needs to show the proper hierachy map not just as a list. Like proper hierachy build out and ability to select appropriately



1) Schedule:
 can you explain what this is and what the full functionality of it is in code.


For 2-4 first finish the admin console fully and make sure i am happy with all functionality then translate that into this over here

2) Business account: -> Need to first do an audit of what is not exposed when business is being setup vs what is exposed as editable.  what needs to be translated 1:1 from the admin console to here.
The label needs to be hierachy sensitive and the functionality to follow the same hierachy discipline. 
remove the subtitile these are the basics.. remove the 4 tiles at the top
the logo needs to be png format and actually needs to replace the logo in the console header and the mobile dashboard header. otherwise default to Forge and flow
business identity needs to be hierachy sensitive so at the location level it need to be location identity and not busness identity
What is locale? explain this functionality for me and how it affects everything
There are some setting for the location and the business that have not been exposed yet for example timezone



3) Business setup
This needs to be hierachy smart, it has to follow the hiearachy rules of dependancy  and the tab names needs to reflect that too, at the business level it says business setup and at the very bottom it says location setup and everything in between too

Remove the subtitle review the timing rules used by shift...
Make the edit timing button bigger and rename it as Edit Time Settings
What is schedule timing? explain this functionality to me so that I can adjust it and how it is presented

Remove the 4 tiles scope..effective etc
Inheritance can be more visual and show the hierchy tree,
effective timing remove the label effective now
then hierachy labels keep it simple as inherited from.. and location profile as x scope (this scope)

Service period same thing remove the labels and for the past midnight roll over just have a small note


4) Locations
This needs proper scope, in that when at a location you do not see location tab rather only at the appropritate hierachy level
In the business you see the full hhierachy and expose the full hierachy functionality crud wise 

5) My account, 
This should move under access
Remove the subtitile 
Profile needs the ability to change all the users own details and this needs to be wired in fully end to end.
remove the subtititle display name email...
The logic is to change account details here and not in the mobile app. This needs to be wired and implemented fully end to end with all user details.

6) Team members:
remove the subtitile invite team members....
Make the Invite team members button bigger
remove the 4 top widget tiles
if not done already for the role list, instead of the 3 dot icon is should be a button saying edit user. We need to add an implementation here to be able to change their email address, name and adjust their role

7) Roles and permissions:
Roles and permissions should move under people
remove the set what each role can do subtiitle...
remove the 4 widgets at the top.


No custom roles -> Rename to Create Custom Role.
remove the subtitle build a custom role....
Remove the role key ux if it has not been removed yet
Remove the subtitle standard roles forge and flow...

8) Sign in Security:
Remove the subtiitle protect your own team....
Remove the 4 tiles at the top
two factor sign in, Behabiour for lost access to your authenticator.. This behaviour is not a link. It's supposed to be a contact admin to remove 2fa, and if admin is logged in then instructions on how to do it under team, Zoom out to see this functionality in mobile and how we can implement it here..
Actually this information and functionality on this page needs to be consolidated into My account, so get rid of sign in and security entirely

9) Active Sessions:
a) Team sessions needs to show actual team member names then it does not need to show operator-web-qa-2026... (what is this string mean expain it to me)
b)Remove the top 4 widget tiles on the screen
For your sessions -> Remove the subtitle devices you are currently....
Also remove the subtitile active sessions for everyone....

10) Can you do a deep dive explanation of what the audit log is. Explain it to me in plain english. zoom out first and look at how it is implemented end to end before you explain it to me, I want to understand it first before I make a decision on how we'll present and use it.

11)Vendor connections -> Rename to Vendor Integration. Rename any instance of connection to integration throughout the page
remove the 4 widget tiles
Reword the intial backfill progress to use the wording intial 60 day benchmark data and the use of the benchmark data
the page throws a could not load vendor connections error.


12) Data accuracy -> Can you explain this entire page to me.
Get rid of the small widget tiles at the top, Labor dollars, guest counts, fallback cards, polling tier.
Make The word Sources Bigger and more visible, Remove the pick the preferred system for labor and covers..
rename where labor dollars come from.. explain this to me, the functionality, how it works and is tied to the architecture, what vendors are a factor here and why. Let's take into consideration the formula below (ask me for the formula if i do not provide it) and look against vendors to where we actually need this functionality.

Covers: Does covers forecast come from reservation integration? (what was the logic again for the 3 types)  Explain this functionality fully to me.

Rename Monitoring to Data freshness -> Make the font bigger.
remove the subtitle check polling cadence and why....
F&F sets polling frequency at the tier level.... Replace this subtitle with Polling is....The standard plan...For more fresh data request....
remove the no poll only vendors connected...
make the request tier change button better, is this wired as an email we receive?
How this applies to your setup rename as Note:
reword polling cadence applies to... -> Polling and data freshness applies to.... 
get rid of your webhook.. replace as Vendors outside this list update in real time...

13) Wage Authority
This is how he blended wage mix is calculated, Double check the code. 
My goal is to have the user interface to match such a setup. 
So foh would have
_ servers @ _/hr = x
etc
then the restauraunt fills that in.
Then at the top of the screen. It should say this applies to x.y.z vendors. because of x. 
check my notes and docs. 
### Wage Mix - blended average hourly rate across all roles
Example: Calculating blended wage mix - full team

**FOH**

- 4 servers @ $16.00/hr = $64.00
- 2 runners @ $16.00/hr = $32.00
- 1 host @ $16.00/hr = $16.00
- 1 bartender @ $16.00/hr = $16.00
- Expo
**BOH**

- 3 line cooks @ $20.00/hr = $60.00
- 2 prep cooks @ $17.50/hr = $35.00
- 2 dishwashers @ $16.50/hr = $33.00

**Management**

- 1 manager @ $26.00/hr = $26.00
- Total hourly cost: $282.00 / 16 people

Blended wage mix: $17.62/hr

Wage authority and Data accuracy can be on the same Data accuracy page.

In cases where setting affect some vendors I need a label and I need to make sure that the code has the ability to edit this list in the admin console ux by each type of setting so this remains upto date and constant.
So an eidtable list for wage, and an editable list for covers and an editable list for polling. Once this list is updated on the admin console it automatically updates on the ops web console in all relevant places


14) NOTIFICATIONS
change First-Connect backfill to First Connect Backfill remove all - use spaces
Reword:
your 60 day historical seed has finished and the connector is now live to, 60 days of your P.o.s data has been uploaded and your initial benchmark is now live
your 60 day historical seed to the same type of wording as above. 
Vendor connection to Vendor Integration
A Vendor e.g Labot management, P.O.S, Reseration system you have been waiting on is now available to connect
Simlify, Audit Chanin Anchor failed into more human terms
A daily audit log -> this description needs to be simpler and needs to explain better with examples what it is for
Manager override applied. Explain in terms of Benchmark overide being applied
weekly plan
a new weekly snapshot was locked in from what? explain better and in human terms


## Mobile Ux
-----------------------
On the home screen what is the live button for?

1) For the notifications inside the notification screen can there be a small tick next each of the notification that pop up to imply "mark as read"
2) The Data tab should be previlaged to only the forge and flow admin users -> This should be set in the seeded role.
3) Under setup: 
The business timing is correct to be view only, Get rid of the review when business subtitle... remove the current timing logo remove the restauraunt local timing controls... Consolidate the business day starts and the shift close ruls to one, then have the widget sectioned in a nicer way for service periods and the other info above it
The manage business timing on operator web should be a button that launches the operator web and uses the same jwt token to open up a live operator web session for them
and the link should link them to the relevant section on operator web not just anywhere

4) Wage Setup; Remove the subtitle review the wage mix used... remove the wording source default wages manage wage setup on operator console also needs the same type of button as timing
This widget should show this break down in view mode only as setup in the ops console

**FOH**
- 4 servers @ $16.00/hr = $64.00
- 2 runners @ $16.00/hr = $32.00
- 1 host @ $16.00/hr = $16.00
- 1 bartender @ $16.00/hr = $16.00
- Expo .... 
**BOH**
- 3 line cooks @ $20.00/hr = $60.00
- 2 prep cooks @ $17.50/hr = $35.00
- 2 dishwashers @ $16.50/hr = $33.00
**Management**
- 1 manager @ $26.00/hr = $26.00
- Total hourly cost: $282.00 / 16 people
Blended wage mix: $17.62/hr


6) Covers setup should also be here, Look at the covers implementation, This allows users to enter covers when the vendors dont support it.
This surface can be edited within the phone. I want it to be the first item on the screen.
If covers setup is set to manual then the user can enter the cover counts.

7) A third tab named integrations should also show live integration status for the different type of vendors, p.o.s, reservation, labor then show the active status and then same thing a button to the operation portal. The demo switch should also be here, so One switch to move from demo to live vendor integrations that are already setup. zoom out to look at the demo switch implementation.

5) Under account two factor auth There should be a direct button here that Enables multi factor authenticator, it should cover all scenarios and be adaptive, when enabled it says enabled/Remove 2fa? when not enrolled it should show enroll, when requested to remove the 2fa and waiting on the 24 hrs window it should say cancel request This used to be in code in history check git if you can find the full implementation and behaviour.

6) GET RID OF THE SUBTITLE REVIEW YOUR SIGN IN DETAils
Rename display name to Name
Manage account on operator web should route to the web ccount same as above buttons mentioned

7) Active sessions: remove the subtitile see where your account...
remove the second active sessions header just say devices currently signed in to your account
for the devices listed it does not need to shoe the ip, just when and what device it is simple nothing else
Then there can be a sign out and sign out of all devices.

The settings tab should be setup, integrations, data (for forge and flow admins), account





On the email and notification pipeline
This is the part that directly serves your "audit code vs docs, no scaffold" directive.

Of nine email templates locked into the codebase, only three are actually wired. The other six exist as markdown files with a doc string explaining why they're deferred. That's textbook scaffold.

Three internal events (backfill complete, backfill failed, audit anchor failure) try to send emails using template IDs that don't exist in the registry. The fanout system silently swallows the failure. Push and in-app notifications still work for these events, but operators never get the emails — and nothing in production tells you that's happening.

Every operator invite — first-admin and team-admin alike — uses Firebase's password-reset email path, not the dedicated invite template that's been built and shipped. Two parallel implementations of the same feature, one wired, one dormant.

This is the wedge you wanted to drive into the codebase. The pattern almost certainly repeats elsewhere — anywhere a feature was specced, partially built, and then the team pivoted without removing the scaffolding. A full "scaffold audit" lane in the code-health wave is the right response.


On the soak and testing capability
Your concern about "live usage for hours, multiple sessions" maps cleanly to what the research recommends: a Dart-native harness extending your existing pressure-test pattern. Roughly six days of work gets you both bug fixes covered by automated regression tests. Another six days gets you a durable forensic kit (heap snapshots uploaded to cloud storage on crash, state-machine property tests, full sign-in flow integrity tests).

For emails and notifications, the recommendation is more pragmatic: roughly ten engineering days plus about $200/month in tooling (Patrol for Flutter device automation, Firebase Test Lab for real-device runs, Mailosaur for capturing test emails, the existing SendGrid event webhook for send-side verification). That's the price tag to be able to actually pressure-test the whole loopback chain — email arrives, click link, land in app, action executes — without manual operator clicks.



