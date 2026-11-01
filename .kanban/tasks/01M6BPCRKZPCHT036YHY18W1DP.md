---
position_column: todo
position_ordinal: '8780'
title: ModelRef accepts a local model path
---
The agent config must take a local path as a model reference, and the format (CoreML or MLX) is found by itself. ModelRef parses owner/name@revision only. Let ModelRef hold a local directory path (an absolute path, or a path that starts with ~ or ./) and keep it apart from a Hub repo id. Pass the path to the Extras loader. Depends on Extras card ^3mnxzqf (HubModelLoader detects the model format from a local path). Related Router card ^zpcsp86 (LiveModelLoader uses HubModelLoader). The ACP agent card in FoundationModelsACPAgent waits for these cards.