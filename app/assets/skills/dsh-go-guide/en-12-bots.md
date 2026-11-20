# DS Bot

DS Bot is a plugin on the host. Each Bot has its own role, chat and memory. Open DS Bot from All features, or tap [Open](dshgo://open/ds-bot). Check the host name at the top: the Bots and group chats below belong to that host.

## Mobile support

**DS Bot isn't on mobile yet** means this host's DS Bot has no usable mobile interface. Tap **Open in DSH Web** to use it there for now. After the plugin is updated and restarted on the host, tap **Retry** to check again. This message doesn't mean your Bots or group chats have been deleted.

If DS Bot isn't detected, the page offers installation or a command to run on the computer. Bots aren't available over DSH Remote; connect to that computer through SSH instead. For the web interface, open DSH Web on the computer.

## Working directory

Open a Bot or group chat, open its details from the top bar, then tap **Working directory**. You are choosing a directory on the connected host; a remote host's directories aren't on your phone.

1. Check **Current directory** and choose from the directories supplied by the host.
2. Tap **Save**, check the directory shown in “Use this working directory?”, then tap **Save** again.

For a Bot, choose **Team workspace** to restore the default. For a group chat, choose **Each Bot’s own directory** to let members use their individual working directories.

If the connection or folder has changed, close the sheet and open it again. If the host refuses a directory, it may be gone, inaccessible or protected; choose another or retry.

## Duplicate a Bot

In the Bot's details, tap **Duplicate Bot**, read the explanation and confirm. The new Bot keeps its job, instructions and model settings, starts with a fresh chat and personal memory, and gets its name from the host. When a model is available, it opens with a greeting.

After copying, the app normally opens the new Bot. If it says the copy will appear in the list shortly, return to the DS Bot list to check; you don't need to duplicate it again. If disconnected, on a different host or in read-only mode, restore the connection and reopen the details before trying.
