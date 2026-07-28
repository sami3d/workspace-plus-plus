import {
  Action,
  ActionPanel,
  closeMainWindow,
  Color,
  Icon,
  Keyboard,
  List,
  showToast,
  Toast,
} from "@raycast/api";
import { execFile } from "node:child_process";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { promisify } from "node:util";
import { randomUUID } from "node:crypto";
import { useCallback, useEffect, useState } from "react";

const execFileAsync = promisify(execFile);
const appBundleID = "com.saint.SpaceRenamer";
const spaceIndexPath = join(
  homedir(),
  "Library",
  "Application Support",
  "Space Renamer",
  "raycast-spaces.json",
);
const switchRequestPath = join(
  homedir(),
  "Library",
  "Application Support",
  "Space Renamer",
  "raycast-switch-request.json",
);

type SpaceItem = {
  id: string;
  storageID: string;
  title: string;
  display: string;
  ordinal: number;
  active: boolean;
};

type SpaceIndexDocument = {
  version: number;
  generatedAt: string;
  spaces: {
    storageID: string;
    name: string;
    ordinal: number;
    displayName: string;
    isActive: boolean;
  }[];
};

function errorMessage(cause: unknown): string {
  if (cause && typeof cause === "object") {
    const message =
      "message" in cause && typeof cause.message === "string"
        ? cause.message.trim()
        : "";
    if (message) return message;
  }
  return String(cause);
}

async function readSpaceIndex(): Promise<SpaceItem[]> {
  const contents = await readFile(spaceIndexPath, "utf8");
  const document = JSON.parse(contents) as SpaceIndexDocument;
  if (document.version !== 1 || !Array.isArray(document.spaces)) {
    throw new Error("Workspace++ returned an unsupported space index.");
  }
  return document.spaces.map((space) => ({
    id: space.storageID,
    storageID: space.storageID,
    title: space.name,
    display: space.displayName,
    ordinal: space.ordinal,
    active: space.isActive,
  }));
}

async function discoverSpaces(): Promise<SpaceItem[]> {
  await execFileAsync("/usr/bin/open", ["-gj", "-b", appBundleID]);
  try {
    return await readSpaceIndex();
  } catch (cause) {
    const missing =
      cause &&
      typeof cause === "object" &&
      "code" in cause &&
      cause.code === "ENOENT";
    if (!missing) throw cause;
  }

  for (let attempt = 0; attempt < 20; attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, 100));
    try {
      return await readSpaceIndex();
    } catch (cause) {
      const missing =
        cause &&
        typeof cause === "object" &&
        "code" in cause &&
        cause.code === "ENOENT";
      if (!missing) throw cause;
    }
  }
  throw new Error("Workspace++ did not publish its live space index.");
}

async function switchToSpace(space: SpaceItem): Promise<void> {
  await execFileAsync("/usr/bin/open", ["-gj", "-b", appBundleID]);
  await mkdir(dirname(switchRequestPath), { recursive: true });
  const temporaryPath = `${switchRequestPath}.${randomUUID()}.tmp`;
  await writeFile(
    temporaryPath,
    JSON.stringify({
      requestID: randomUUID(),
      storageID: space.storageID,
    }),
    "utf8",
  );
  await rename(temporaryPath, switchRequestPath);
  await closeMainWindow();
}

export default function Command() {
  const [spaces, setSpaces] = useState<SpaceItem[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string>();

  const refresh = useCallback(async () => {
    setIsLoading(true);
    setError(undefined);

    try {
      const liveSpaces = await discoverSpaces();
      setSpaces(liveSpaces);
      if (liveSpaces.length === 0) {
        setError("Workspace++ returned no live spaces.");
      }
    } catch (cause) {
      setSpaces([]);
      setError(errorMessage(cause));
    } finally {
      setIsLoading(false);
    }
  }, []);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  return (
    <List
      isLoading={isLoading}
      searchBarPlaceholder="Search live space names…"
      navigationTitle="Switch Space"
    >
      {spaces.length === 0 && !isLoading ? (
        <List.EmptyView
          icon={Icon.ExclamationMark}
          title="No Spaces Available"
          description={error ?? "Open Workspace++ and refresh."}
          actions={
            <ActionPanel>
              <Action
                title="Refresh Spaces"
                icon={Icon.ArrowClockwise}
                onAction={refresh}
              />
            </ActionPanel>
          }
        />
      ) : (
        spaces.map((space) => (
          <List.Item
            key={space.id}
            id={space.id}
            icon={{
              source: space.active ? Icon.CheckCircle : Icon.Desktop,
              tintColor: space.active ? Color.Green : Color.SecondaryText,
            }}
            title={space.title}
            subtitle={space.display}
            keywords={[
              space.display,
              `Desktop ${space.ordinal}`,
              space.active ? "current active" : "desktop space",
            ]}
            accessories={
              space.active
                ? [{ text: "Current", icon: Icon.Checkmark }]
                : undefined
            }
            actions={
              <ActionPanel>
                <Action
                  title={
                    space.active ? "Stay on This Space" : "Switch to Space"
                  }
                  icon={Icon.ArrowRight}
                  onAction={async () => {
                    try {
                      await switchToSpace(space);
                    } catch (cause) {
                      await showToast({
                        style: Toast.Style.Failure,
                        title: "Couldn’t switch spaces",
                        message: errorMessage(cause),
                      });
                    }
                  }}
                />
                <Action
                  title="Refresh Spaces"
                  icon={Icon.ArrowClockwise}
                  shortcut={Keyboard.Shortcut.Common.Refresh}
                  onAction={refresh}
                />
              </ActionPanel>
            }
          />
        ))
      )}
    </List>
  );
}
