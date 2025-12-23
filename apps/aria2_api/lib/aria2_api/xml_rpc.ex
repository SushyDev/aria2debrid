defmodule Aria2Api.XmlRpc do
  @moduledoc """
  XML-RPC parser and encoder for aria2 API.

  Sonarr/Radarr use XML-RPC (not JSON-RPC) to communicate with aria2.

  ## Request Format

  ```xml
  <?xml version="1.0" encoding="utf-8"?>
  <methodCall>
    <methodName>aria2.getVersion</methodName>
    <params>
      <param><value><string>token:secret</string></value></param>
    </params>
  </methodCall>
  ```

  ## Response Format

  ```xml
  <?xml version="1.0" encoding="utf-8"?>
  <methodResponse>
    <params>
      <param>
        <value>
          <struct>
            <member>
              <name>version</name>
              <value><string>1.37.0</string></value>
            </member>
          </struct>
        </value>
      </param>
    </params>
  </methodResponse>
  ```

  ## Fault Response

  ```xml
  <?xml version="1.0" encoding="utf-8"?>
  <methodResponse>
    <fault>
      <value>
        <struct>
          <member>
            <name>faultCode</name>
            <value><int>-32600</int></value>
          </member>
          <member>
            <name>faultString</name>
            <value><string>Invalid Request</string></value>
          </member>
        </struct>
      </value>
    </fault>
  </methodResponse>
  ```
  """

  import SweetXml

  @doc """
  Parse an XML-RPC method call request.

  Returns `{:ok, method_name, params}` or `{:error, reason}`.
  """
  @spec parse_request(String.t()) :: {:ok, String.t(), list()} | {:error, String.t()}
  def parse_request(xml) do
    try do
      doc = SweetXml.parse(xml, quiet: true)

      method_name =
        doc
        |> xpath(~x"//methodCall/methodName/text()"s)

      if method_name == "" do
        {:error, "Missing methodName"}
      else
        params = parse_params(doc)
        {:ok, method_name, params}
      end
    rescue
      e ->
        {:error, "XML parse error: #{inspect(e)}"}
    catch
      :exit, {:fatal, {reason, _, _, _}} ->
        {:error, "XML parse error: #{inspect(reason)}"}

      :exit, reason ->
        {:error, "XML parse error: #{inspect(reason)}"}
    end
  end

  defp parse_params(doc) do
    doc
    |> xpath(~x"//methodCall/params/param"l)
    |> Enum.map(&parse_value/1)
  end

  defp parse_value(param_node) do
    # Get the value element
    value_node = xpath(param_node, ~x"./value")
    parse_typed_value(value_node)
  end

  defp parse_typed_value(nil), do: nil

  defp parse_typed_value(value_node) do
    cond do
      # String value
      (str = xpath(value_node, ~x"./string/text()"s)) != "" ->
        str

      # Integer value
      (int_str = xpath(value_node, ~x"./int/text()"s)) != "" ->
        String.to_integer(int_str)

      (int_str = xpath(value_node, ~x"./i4/text()"s)) != "" ->
        String.to_integer(int_str)

      # Boolean value
      (bool_str = xpath(value_node, ~x"./boolean/text()"s)) != "" ->
        bool_str == "1"

      # Double value
      (double_str = xpath(value_node, ~x"./double/text()"s)) != "" ->
        String.to_float(double_str)

      # Base64 value
      (b64 = xpath(value_node, ~x"./base64/text()"s)) != "" ->
        Base.decode64!(b64)

      # Array value
      xpath(value_node, ~x"./array") != nil ->
        value_node
        |> xpath(~x"./array/data/value"l)
        |> Enum.map(&parse_typed_value/1)

      # Struct value (dictionary)
      xpath(value_node, ~x"./struct") != nil ->
        value_node
        |> xpath(~x"./struct/member"l)
        |> Enum.map(fn member ->
          name = xpath(member, ~x"./name/text()"s)
          value = parse_typed_value(xpath(member, ~x"./value"))
          {name, value}
        end)
        |> Map.new()

      # Raw text (no type wrapper - treated as string in XML-RPC)
      true ->
        xpath(value_node, ~x"./text()"s) |> String.trim()
    end
  end

  @doc """
  Encode a successful XML-RPC response.
  """
  @spec encode_response(term()) :: String.t()
  def encode_response(result) do
    """
    <?xml version="1.0" encoding="utf-8"?>
    <methodResponse>
      <params>
        <param>
          #{encode_value(result)}
        </param>
      </params>
    </methodResponse>
    """
    |> String.trim()
  end

  @doc """
  Encode an XML-RPC fault response.
  """
  @spec encode_fault(integer(), String.t()) :: String.t()
  def encode_fault(code, message) do
    """
    <?xml version="1.0" encoding="utf-8"?>
    <methodResponse>
      <fault>
        <value>
          <struct>
            <member>
              <name>faultCode</name>
              <value><int>#{code}</int></value>
            </member>
            <member>
              <name>faultString</name>
              <value><string>#{escape_xml(message)}</string></value>
            </member>
          </struct>
        </value>
      </fault>
    </methodResponse>
    """
    |> String.trim()
  end

  defp encode_value(value) when is_binary(value) do
    "<value><string>#{escape_xml(value)}</string></value>"
  end

  defp encode_value(value) when is_integer(value) do
    "<value><int>#{value}</int></value>"
  end

  defp encode_value(value) when is_float(value) do
    "<value><double>#{value}</double></value>"
  end

  defp encode_value(true), do: "<value><boolean>1</boolean></value>"
  defp encode_value(false), do: "<value><boolean>0</boolean></value>"
  defp encode_value(nil), do: "<value><string></string></value>"

  defp encode_value(value) when is_list(value) do
    items = Enum.map_join(value, "\n", &encode_value/1)

    """
    <value>
      <array>
        <data>
          #{items}
        </data>
      </array>
    </value>
    """
  end

  defp encode_value(value) when is_map(value) do
    members =
      value
      |> Enum.map(fn {k, v} ->
        """
        <member>
          <name>#{escape_xml(to_string(k))}</name>
          #{encode_value(v)}
        </member>
        """
      end)
      |> Enum.join("\n")

    """
    <value>
      <struct>
        #{members}
      </struct>
    </value>
    """
  end

  defp escape_xml(str) when is_binary(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp escape_xml(other), do: escape_xml(to_string(other))
end
