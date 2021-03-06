defmodule Guardian.Plug.VerifyHeaderTest do
  use ExUnit.Case, async: true
  use Plug.Test

  alias Guardian.Claims
  alias Guardian.Keys
  alias Guardian.Plug.VerifyHeader
  alias Plug.Conn

  setup do
    config = Application.get_env(:guardian, Guardian)
    algo = hd(Dict.get(config, :allowed_algos))
    secret = Dict.get(config, :secret_key)

    jose_jws = %{"alg" => algo}
    jose_jwk = %{"kty" => "oct", "k" => :base64url.encode(secret)}
    claims = Claims.app_claims(%{ "sub" => "user", "aud" => "aud" })
    { _, jwt } = JOSE.JWT.sign(jose_jwk, jose_jws, claims) |> JOSE.JWS.compact

    { :ok, conn: conn(:get, "/"), jwt: jwt, claims: claims, jose_jws: jose_jws, jose_jwk: jose_jwk, secret: secret }
  end

  test "with no JWT in the session at a default location", context do
    conn = VerifyHeader.call(context.conn, [])
    assert conn.assigns[Keys.claims_key] == nil
    assert conn.assigns[Keys.jwt_key] == nil
  end

  test "with no JWT in the session at a specified location", context do
    conn = VerifyHeader.call(context.conn, key: :secret)
    assert conn.assigns[Keys.claims_key(:secret)] == nil
    assert conn.assigns[Keys.jwt_key(:secret)] == nil
  end

  test "with a valid JWT in the session at the default location", context do
    the_conn = context.conn |> put_req_header("authorization", context.jwt)
    conn = VerifyHeader.call(the_conn, [])
    assert conn.assigns[Keys.claims_key] == { :ok, context.claims }
    assert conn.assigns[Keys.jwt_key] == context.jwt
  end

  test "with a valid JWT in the session at a specified location", context do
    the_conn = context.conn |> put_req_header("authorization", context.jwt)
    conn = VerifyHeader.call(the_conn, key: :secret)
    assert conn.assigns[Keys.claims_key(:secret)] == { :ok, context.claims }
    assert conn.assigns[Keys.jwt_key(:secret)] == context.jwt
  end

  test "with an existing session in another location", context do
    the_conn = context.conn
    |> put_req_header("authorization", context.jwt)
    |> Conn.assign(Keys.claims_key, context.claims)
    |> Conn.assign(Keys.jwt_key, context.jwt)

    conn = VerifyHeader.call(the_conn, key: :secret)
    assert conn.assigns[Keys.claims_key(:secret)] == { :ok, context.claims }
    assert conn.assigns[Keys.jwt_key(:secret)] == context.jwt
  end

  test "with a realm specified", context do
    the_conn = put_req_header(context.conn, "authorization", "Bearer #{context.jwt}")

    opts = VerifyHeader.init(realm: "Bearer")

    conn = VerifyHeader.call(the_conn, opts)
    assert conn.assigns[Keys.claims_key] == { :ok, context.claims }
    assert conn.assigns[Keys.jwt_key] == context.jwt
  end

  test "with a realm specified and multiple auth headers", context do
    claims2 = Claims.app_claims(%{ "sub" => "user2", "aud" => "aud2" })
    { _, jwt2 } = JOSE.JWT.sign(context.jose_jwk, context.jose_jws, claims2) |> JOSE.JWS.compact

    the_conn = context.conn
    |> put_req_header("authorization", "Bearer #{context.jwt}")
    |> put_req_header("authorization", "Client #{jwt2}")

    opts = VerifyHeader.init(realm: "Client")

    conn = VerifyHeader.call(the_conn, opts)
    assert conn.assigns[Keys.claims_key] == { :ok, claims2 }
    assert conn.assigns[Keys.jwt_key] == jwt2
  end

  test "pulls different tokens into different locations", context do
    claims2 = Claims.app_claims(%{ "sub" => "user2", "aud" => "aud2" })
    { _, jwt2 } = JOSE.JWT.sign(context.jose_jwk, context.jose_jws, claims2) |> JOSE.JWS.compact

    # Can't use the put_req_header here since it overrides previous values
    the_conn = %{ context.conn | req_headers: [{"authorization", "Bearer #{context.jwt}"}, {"authorization", "Client #{jwt2}"}] }

    defaultOpts = VerifyHeader.init(realm: "Bearer")
    clientOpts = VerifyHeader.init(realm: "Client", key: :client)

    conn = the_conn
    |> VerifyHeader.call(defaultOpts)
    |> VerifyHeader.call(clientOpts)

    assert conn.assigns[Keys.claims_key(:client)] == { :ok, claims2 }
    assert conn.assigns[Keys.jwt_key(:client)] == jwt2
    assert conn.assigns[Keys.claims_key] == { :ok, context.claims }
    assert conn.assigns[Keys.jwt_key] == context.jwt
  end
end
