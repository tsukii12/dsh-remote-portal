# Subagents and agent teams

When there's a lot to do, the AI can hand part of the work to subagents, or split it with several agents on a team. Both show up in the app: progress, tasks, and a tap to pick the conversation back up.

## Subagents

A subagent is a conversation the AI sends out from the current chat, with its own context and tools; the original chat is its parent. The chat header shows a **Subagents** capsule with how many were sent, and a dot on it breathes while any of them runs.

Tap the capsule for the list: a lineage tree, each row naming the task and its state; tap a row to open that conversation. Open it when none were sent and it says **No subagents sent**.

## Finding subagents

- The chat header capsule: the team when Agent Teams is on, otherwise the number of subagents sent.
- **Subagents** in All features: opens this chat's **Chat details** on the subagents tab.

<!-- nav: chatChats,catalogAllFeatures,catalogSubagents -->
`Chats › All features › Subagents`

<!-- nav: chatChats,catalogAllFeatures,catalogChatDetails -->
`Chats › All features › Chat details`

## Moving between a parent and its subagents

A subagent conversation is titled with the task its parent gave it; the top-left key is not the menu but a back key naming the parent conversation, and tapping it returns to the chat that sent the subagent. A subagent conversation shows no model chip; its model follows the parent chat's settings.

## Agent teams

A team lets several agents in one lead chat share the work: they share a task board that records who does what and how far along it is.

<!-- nav: chatChats,catalogAllFeatures,catalogAgentTeam -->
`Chats › All features › Agent team`

[Open](dshgo://open/agent-team)

The page has three tabs, **Members**, **Tasks** and **Messages**:

- **Members**: each member and its state; the team's lead chat is marked **Owner**, the conversation you're in is marked **Current**. Tap a member to open their conversation.
- **Tasks**: grouped as **To do**, **In progress** and **Done**. Under a task are its owner, dependencies and ID; tap it for its state (**Ready to start**, **Waiting on dependencies**, **In progress**, **Completed**), its **Dependencies** and **Write scopes**, with **Overlapping write scopes** flagged when two collide.
- **Messages**: what members send each other, labelled with who sent it to whom; tap one for the full text. With no messages yet there's an empty state, and when some members' messages couldn't be read there's **Retry**.

## Turning the team on

The team is a capability of the host's engine and has to be turned on. When the host supports it but it's off, the page says **Agent team is off** and offers **Turn on team**; on a host without the capability it says **No agent team on this host**. It can't be turned on in safe mode.

With no chat open the page asks you to **Open a chat first**; when the team can't be read it says **Couldn’t load the team** and offers **Retry**.

The AI forms the team in a chat: ask it to put a team together and it assigns work on the task board. Once there are members, come back here to see who is doing what.

## Subagent settings

<!-- nav: commonSettings,engineSettingsTitle,engineSubagentTitle -->
`Settings › Engine parameters › Subagent`

- **Limits**: how many levels of delegation deep it may go, and how many subagents may run at once.
- **Model selection**: when on, restricts which models a subagent may use; **Keep at least one model**. With no models yet, **Add provider** first.

## Things to know

- Whether a team can be turned on depends on the current host's engine; safe mode doesn't allow it.
- A subagent belongs to the chat that sent it: deleting the parent chat deletes its subagent conversations too.
- Subagents and teams get their data from the current host; with no connection the team page only shows the offline notice.
