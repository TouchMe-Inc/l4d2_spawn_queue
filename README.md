# About spawn_queue
The plugin sets the queue of infected in the order of their death.

## ConVars
| ConVar               | Value         | Description                                                                                     |
| -------------------- | ------------- | ----------------------------------------------------------------------------------------------- |
| sm_spawn_queue_mode  | 0             | The queue is made up of the order of deaths: 0 - Original; 1 - Dynamic; 2 - Strict 3cap         |
| sm_spawn_queue_first_hit_required  | 0             | Bitmask of special infected classes required in the first attack wave: 1 - SMOKER, 2 - BOOMER, 4 - HUNTER, 8 - SPITTER, 16 - JOCKEY, 32 - CHARGER. Examples: 1 + 32 = 33 forces SMOKER and CHARGER         |

## Require
* [Left4DHooks](https://github.com/SilvDev/Left4DHooks)