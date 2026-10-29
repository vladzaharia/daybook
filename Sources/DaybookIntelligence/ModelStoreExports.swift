// The model store moved to its own target (DaybookModelStore) so the iPhone can download and verify
// live models without the Mac's engines. Re-exported, so everything that imports DaybookIntelligence
// sees it as before.
@_exported import DaybookModelStore
