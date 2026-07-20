# The `pikvm` package scope. Add PiKVM derivations here; each is called with
# callPackage from within the scope, so they can depend on one another
# (e.g. kvmd referencing ustreamer) via `pikvm.<name>`.
pikvm: {
  # ustreamer = pikvm.callPackage ./ustreamer { };
  # kvmd      = pikvm.callPackage ./kvmd { };
}
