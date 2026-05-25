import Route from "@ember/routing/route";
import { inject as service } from "@ember/service";

export default class UserPreferencesAiTokensRoute extends Route {
  @service currentUser;

  model() {
    // All data is loaded by the controller on setupController
    return {};
  }

  setupController(controller /*, model */) {
    super.setupController(...arguments);
    controller.loadTokens();
  }
}
