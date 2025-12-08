defmodule AgentsDemoWeb.UserLive.Confirmation do
  use AgentsDemoWeb, :live_view

  alias AgentsDemo.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen w-screen bg-[var(--color-background)] overflow-hidden">
      <div class="flex flex-1 items-center justify-center p-8">
        <div class="max-w-md w-full">
          <div class="mb-8 flex justify-center">
            <.link navigate={~p"/"} class="no-underline">
              <div class="w-16 h-16 rounded-full bg-[var(--color-primary)] flex items-center justify-center">
                <.icon name="hero-chat-bubble-left-right" class="w-10 h-10 text-white" />
              </div>
            </.link>
          </div>

          <div class="bg-[var(--color-surface)] border border-[var(--color-border)] rounded-xl p-8 shadow-lg">
            <div class="text-center mb-6">
              <h1 class="text-3xl font-bold text-[var(--color-text-primary)] mb-2">
                Welcome {@user.email}
              </h1>
            </div>

            <.form
              :if={!@user.confirmed_at}
              for={@form}
              id="confirmation_form"
              phx-mounted={JS.focus_first()}
              phx-submit="submit"
              action={~p"/users/log-in?_action=confirmed"}
              phx-trigger-action={@trigger_submit}
              class="space-y-3"
            >
              <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
              <.button
                name={@form[:remember_me].name}
                value="true"
                phx-disable-with="Confirming..."
                class="btn btn-primary w-full"
              >
                Confirm and stay logged in
              </.button>
              <.button phx-disable-with="Confirming..." class="btn btn-primary btn-soft w-full">
                Confirm and log in only this time
              </.button>
            </.form>

            <.form
              :if={@user.confirmed_at}
              for={@form}
              id="login_form"
              phx-submit="submit"
              phx-mounted={JS.focus_first()}
              action={~p"/users/log-in"}
              phx-trigger-action={@trigger_submit}
              class="space-y-3"
            >
              <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
              <%= if @current_scope do %>
                <.button phx-disable-with="Logging in..." class="btn btn-primary w-full">
                  Log in
                </.button>
              <% else %>
                <.button
                  name={@form[:remember_me].name}
                  value="true"
                  phx-disable-with="Logging in..."
                  class="btn btn-primary w-full"
                >
                  Keep me logged in on this device
                </.button>
                <.button phx-disable-with="Logging in..." class="btn btn-primary btn-soft w-full">
                  Log me in only this time
                </.button>
              <% end %>
            </.form>

            <div
              :if={!@user.confirmed_at}
              class="mt-6 p-4 bg-blue-50 dark:bg-blue-900/20 border border-blue-200 dark:border-blue-800 rounded-lg"
            >
              <p class="text-sm text-blue-900 dark:text-blue-100 m-0">
                <strong>Tip:</strong>
                If you prefer passwords, you can enable them in the user settings.
              </p>
            </div>
          </div>

          <div class="mt-6 text-center">
            <.link
              navigate={~p"/"}
              class="text-sm text-[var(--color-text-secondary)] hover:text-[var(--color-primary)] no-underline"
            >
              ← Back to home
            </.link>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    if user = Accounts.get_user_by_magic_link_token(token) do
      form = to_form(%{"token" => token}, as: "user")

      {:ok, assign(socket, user: user, form: form, trigger_submit: false),
       temporary_assigns: [form: nil]}
    else
      {:ok,
       socket
       |> put_flash(:error, "Magic link is invalid or it has expired.")
       |> push_navigate(to: ~p"/users/log-in")}
    end
  end

  @impl true
  def handle_event("submit", %{"user" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: "user"), trigger_submit: true)}
  end
end
