/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import { load } from 'js-yaml';

test('product builds of other branches wait for approval before any stage starts', async () => {
	type Dependency = string | Record<string, string[]>;
	type Stage = { stage: string; dependsOn?: Dependency[] };
	// Each entry is a stage, or a template condition selecting a list of stages or an error message
	type StageEntry = Stage | Record<string, (Stage | Record<string, string>)[]>;
	const isStage = (value: object): value is Stage => 'stage' in value;
	const pipeline = load(await readFile(new URL('../../azure-pipelines/product-build.yml', import.meta.url), 'utf8')) as {
		extends: { parameters: { stages: StageEntry[] } };
	};
	const stages = pipeline.extends.parameters.stages.flatMap((entry): { condition?: string; stage: Stage }[] => isStage(entry)
		? [{ stage: entry }]
		: Object.entries(entry).flatMap(([condition, values]) => values.filter(isStage).map(stage => ({ condition, stage }))));
	// The condition guarding each dependency on ApproveBuild, undefined when unconditional
	const approvalConditions = (dependency: Dependency): (string | undefined)[] => typeof dependency === 'string'
		? (dependency === 'ApproveBuild' ? [undefined] : [])
		: Object.entries(dependency).filter(([, names]) => names.includes('ApproveBuild')).map(([condition]) => condition);
	assert.deepStrictEqual({
		startsImmediately: stages.filter(({ stage }) => !stage.dependsOn?.length).map(({ stage }) => stage.stage),
		approvalConditions: [...new Set([
			...stages.filter(({ stage }) => stage.stage === 'ApproveBuild').map(({ condition }) => condition),
			...stages.flatMap(({ stage }) => stage.dependsOn?.flatMap(approvalConditions) ?? []),
		])],
	}, {
		startsImmediately: ['ApproveBuild'],
		approvalConditions: ['${{ if eq(variables.VSCODE_REQUIRE_BUILD_APPROVAL, true) }}'],
	});
});
