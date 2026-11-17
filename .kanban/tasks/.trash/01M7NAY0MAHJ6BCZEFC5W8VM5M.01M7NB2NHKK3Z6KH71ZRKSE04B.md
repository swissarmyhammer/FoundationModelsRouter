---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: The large preset uses Qwen3.8-27B-8bit with the MTP-8bit drafter
---
Requested by ACPAgent for the user, who chose to change the default over adding a separate preset. `ModelChoices.generation[0]`, and so the `large` profile in both standard and flash, becomes `ModelRef(repo: "mlx-community/Qwen3.8-27B-8bit", drafter: "mlx-community/Qwen3.8-27B-MTP-8bit")`.

- The drafter loads by `model_type` through MTPDrafterTypeRegistry. `MTPDrafterRegistry.qwen3_8_27b_mtp_4bit` is only a preset, so mlx needs no change. A gated real load will prove that.
- Check the memory fit under kvBits 8: the router sizes the drafter as part of the slot.
- TDD: update ModelChoicesTests and ModelProfilesTests first, then ModelChoices and the docs. Push, then send the SHA to foundationmodelsacpagent-22.