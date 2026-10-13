import QtQuick

// Minimal stand-in for iNiR's StyledListView. The dock uses it purely as a
// ListView (contentWidth/Height, itemAtIndex, spacing, orientation, model and
// its own transition overrides), so a plain ListView satisfies the contract.
ListView {
    id: root
}
