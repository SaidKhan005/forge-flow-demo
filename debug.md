
# Emails and notifications
--------------------------------------------------------------------------
password reset and the rest of the emails loopback to app/latest apps
invite emails
live emails and notification tests
----------------------------------------------------------------------------------------------------------------------------------
## UX
# Main concern now is making the ux user friendly for both the console and the mobile app.
---------------------------------------------

I want you to do an audit of permissions and roles,
What is support role, dowe need it as a seed role (i am thinking not if we can create custom roles), is the rebac relationship based access control implemented. in all the phases and docs is role functionality fully done if not it has to be done now. I would like the ability in hte begining to create standard seed roles.
What tye of roles are there, What actor and actor kind labels do we use we need to focus on making this more user or restauraunt friendly, Are roles applied the same way as the hierachy state is for busines functionality, when setting up roles and applying at different hierchy levels what does that look like in the ux, does it match the rest of the hierachy scope functions and is it wired end to end. 
Same hierachy logic should apply to audit hash and hash chains/ log chains; This enable better log filtering. 
The rule has to be every single bit of infomantion or functionlity on the screen has to be wired this way end to end and has to be presented in the ux in the same exact consistent way. 
We need to zoom out and create a master list for this and an end to end implementation plan

This is a problem statemet i want to audit and address "The product rule should be something like:
If a role can manage team members, it should include team.users.view.
If a role can create/edit roles, it should probably include team.roles.view and team.users.view.
If a role can assign roles, it should include team.roles.view and enough user visibility to choose targets.
If a role is location-scoped, the UI should make clear that org-wide/operator-wide actions will not be available.
Seeded roles should be shown as baseline/read-only.
Custom roles should be editable, but the editor should prevent or warn about “orphan” permission combos that technically grant an action but hide the surface needed to use it.
So yes: the backend already resolves granted permissions, including custom roles. The next polish is making the role-permission editor guide people into coherent bundles so nobody creates a role that has “permission to do X” but cannot see the screen where X "

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

## Mobile
-----------------------
1) The notification button on the home screen has a stale number 3 on it but there is nothing in the notifications
2) The Data tab should be previlaged to only the forge and flow admin users
3) Under setup: The business timing is correct to be view only, Get rid of the review when business subtitle... remove the current timing logo remove the restauraunt local timing controls... Consolidate the business day starts and the shift close ruls to one, then have the widget sectioned in a nicer way for service periods and the other info above it
The manage business timing on operator web should be a button that launches the operator web and uses the same jwt token to open up a live operator web session for them
and the link should link them to the relevant section on operator web not just anywhere
4) Wage setup; Remove the subtitle review the wage mix used... remove the wording source default wages manage wage setup on operator console also needs the same type of button as timing
6) Covers setup should also be here, Look at the covers implementation, This allows users to enter covers when the vendors dont support it.
7) A third tab named integrations should also show live integration status for the different type of vendors, p.o.s, reservation, labor then show the active status and then same thing a button to the operation portal. The demo switch should also be here, so One switch to move from demo to live vendor integrations that are already setup. zoom out to look at the demo switch implementation.
5) Under account two factor auth There should be a direct button here taht Enables multi factor authenticator, it should cover all bases, when enabled it says enabled when not enrolled it should show enroll...(when enrolled, when not enrolled, when request to remove the 2fa and waiting, cancel request) This used to be in code in history check git

6) aCCOUNT, GET RID OF THE SUBTITLE REVIEW YOUR SIGN IN DETAULS
Rename display name to Name
Manage account on operator web should route to the web ccount same as above features

7) Active sessions: remove the subtitile see where your account...
remove the second active sessions header just say devices currently signed in to your account
for the devices listed it does not need to shoe the ip, just when and what device it is simple nothing else
Then there can be a sign out and sign out of all devices.


On the home screen what is the live button for?