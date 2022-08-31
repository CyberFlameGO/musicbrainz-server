/*
 * @flow strict
 * Copyright (C) 2022 MetaBrainz Foundation
 *
 * This file is part of MusicBrainz, the open internet music database,
 * and is licensed under the GPL version 2, or (at your option) any
 * later version: http://www.gnu.org/licenses/gpl-2.0.txt
 */

/*
 * `getCatalystContext` can be used to retrieve the sanitized Catalyst context
 * data stored in the global JS namespace
 * (see root/layout/components/globalsScript.mjs).  This is mainly for use
 * outside of a React component; inside a component you can and should just
 * use the React context (not to be confused with the Catalyst context) API.
 */
export function getCatalystContext(): SanitizedCatalystContextT {
  const $c = window[GLOBAL_JS_NAMESPACE]?.$c;
  invariant($c, 'Catalyst context not found in GLOBAL_JS_NAMESPACE');
  return $c;
}

export function getSourceEntityData():
    | CoreEntityT
    | {+entityType: CoreEntityTypeT}
    | null {
  const $c = getCatalystContext();
  return $c.stash.source_entity ?? null;
}