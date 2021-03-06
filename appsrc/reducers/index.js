
import {combineReducers} from 'redux'

import history from './history'
import modals from './modals'
import globalMarket from './global-market'
import market from './market'
import system from './system'
import setup from './setup'
import rememberedSessions from './remembered-sessions'
import session from './session'
import i18n from './i18n'
import ui from './ui'
import selfUpdate from './self-update'
import preferences from './preferences'
import tasks from './tasks'
import downloads from './downloads'
import status from './status'

const reducer = combineReducers({
  history,
  modals,
  globalMarket,
  market,
  system,
  setup,
  rememberedSessions,
  session,
  i18n,
  ui,
  selfUpdate,
  preferences,
  tasks,
  downloads,
  status
})
export default reducer
