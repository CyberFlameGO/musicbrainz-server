/*
 * @flow strict-local
 * Copyright (C) 2020 MetaBrainz Foundation
 *
 * This file is part of MusicBrainz, the open internet music database,
 * and is licensed under the GPL version 2, or (at your option) any
 * later version: http://www.gnu.org/licenses/gpl-2.0.txt
 */

import * as React from 'react';

import {compareStrings} from '../static/scripts/common/utility/compare';
import hydrate from '../utility/hydrate';

export type PostParametersT = {
  +[param: string]: string,
  ...
};

type PropsT = {
  +params: PostParametersT,
};

const PostParameters = ({
  params,
}: PropsT): React.MixedElement => {
  const [expanded, setExpanded] = React.useState(false);

  const sortedParams = Object.entries(params).sort(
    (a, b) => compareStrings(a[0], b[0]),
  );

  return (
    <>
      <a
        className="expand-link"
        href="#"
        onClick={(event) => {
          event.preventDefault();
          setExpanded(!expanded);
        }}
      >
        {expanded ? '▼ ' : '▶ '}
        {l('Data submitted with this request')}
      </a>
      <table className={expanded ? null : 'all-collapsed'}>
        <tbody>
          {sortedParams.map(([param, value], index) => {
            const id = 'post-parameter-' + String(index);
            return (
              <tr key={param}>
                <td>
                  <label htmlFor={id}>
                    {param}
                  </label>
                </td>
                <td>
                  <input
                    defaultValue={value}
                    id={id}
                    name={param}
                    size="50"
                    type="text"
                  />
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </>
  );
};

export default (hydrate(
  'div.post-parameters',
  PostParameters,
): React.AbstractComponent<PropsT, void>);