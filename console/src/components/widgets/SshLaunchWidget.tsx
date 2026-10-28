// `ssh://` URIs are handled by the OS/browser's registered SSH client if
// one's configured to catch that scheme - no in-browser terminal here by
// design (that's ttyd/Wetty territory if this ever needs to be reachable
// from a device without a native SSH client).
export function SshLaunchWidget({ host }: { host: string }) {
  return (
    <a className="widget widget-ssh" href={`ssh://${host}`}>
      ⌁ SSH
    </a>
  );
}
